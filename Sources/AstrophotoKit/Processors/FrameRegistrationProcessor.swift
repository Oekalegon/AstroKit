import Foundation
import Metal
import TabularData
import os

// MARK: - Internal types

private struct StarPoint {
    let x: Double
    let y: Double
}

private struct QuadDescriptor {
    let dx3: Double   // descriptor_x3
    let dy3: Double   // descriptor_y3
    let dx4: Double   // descriptor_x4
    let dy4: Double   // descriptor_y4
    // Actual image coordinates of the 4 stars
    let s1: StarPoint
    let s2: StarPoint
    let s3: StarPoint
    let s4: StarPoint
}

private struct SimilarityTransform {
    let tx: Double         // translation x (pixels)
    let ty: Double         // translation y (pixels)
    let rotation: Double   // radians
    let scale: Double      // uniform scale factor

    var rotationDeg: Double { rotation * 180.0 / .pi }

    static let identity = SimilarityTransform(tx: 0, ty: 0, rotation: 0, scale: 1)
}

private struct FrameStats {
    let starCount: Int
    let meanFWHM: Double
    let medianFWHM: Double
    let meanEccentricity: Double
    let meanPositionAngle: Double  // degrees
    let meanFlux: Double
    let skyBackground: Double      // estimated sky level (ADU)
    let skyNoise: Double           // robust σ of sky background (NMAD, ADU)
}

private struct RegistrationRow {
    let frameIndex: Int
    let transform: SimilarityTransform
    let matchCount: Int
    let rmse: Double
    let stats: FrameStats
    let success: Bool
}

// MARK: - Processor

public struct FrameRegistrationProcessor: Processor {
    public var id: String { "frame_registration" }
    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let frameSet = inputs["input_frames"] as? FrameSet else {
            throw ProcessorExecutionError.missingRequiredInput("input_frames")
        }
        guard !frameSet.frames.isEmpty else {
            throw ProcessorExecutionError.executionFailed("input_frames FrameSet is empty")
        }

        let referenceFrameParam = parameters["reference_frame"]?.intValue ?? -1
        let matchThreshold      = parameters["match_threshold"]?.doubleValue ?? 0.05
        let minMatches          = parameters["min_matches"]?.intValue ?? 4
        let ransacIterations    = parameters["ransac_iterations"]?.intValue ?? 100
        let inlierThreshold     = parameters["inlier_threshold"]?.doubleValue ?? 3.0
        let blurRadius          = parameters["blur_radius"]?.doubleValue ?? 3.0
        let thresholdValue      = parameters["threshold_value"]?.doubleValue ?? 3.0
        let erosionKernel       = parameters["erosion_kernel_size"]?.intValue ?? 3
        let dilationKernel      = parameters["dilation_kernel_size"]?.intValue ?? 3
        let maxStars            = parameters["max_stars"]?.intValue ?? 100
        let minDistancePct      = parameters["min_distance_percent"]?.doubleValue ?? 1.0
        let kNeighbors          = parameters["k_neighbors"]?.intValue ?? 5
        // max deviation of the computed pixel-scale ratio from 1.0 (same-equipment constraint)
        let maxScaleDeviation   = parameters["max_scale_deviation"]?.doubleValue ?? 0.05
        // Lowe's ratio-test threshold: reject a match if best/second-best >= this value
        let ratioThreshold      = parameters["ratio_threshold"]?.doubleValue ?? 0.8
        // Minimum fraction of frames that must be successfully registered
        let minSuccessRate      = parameters["min_success_rate"]?.doubleValue ?? 0.75
        // Extended-source filter: reject detected sources whose avg FWHM exceeds this multiple
        // of the per-frame median FWHM. Removes nebula blobs/gradients misidentified as stars.
        // Set to 0 to disable.
        let maxFWHMRatio        = parameters["max_fwhm_ratio"]?.doubleValue ?? 2.5

        // Run star detection on every frame
        var perFrame: [(quads: [QuadDescriptor], stats: FrameStats)] = []
        for frame in frameSet.frames {
            let (quads, stats) = try detectStarsAndQuads(
                frame: frame,
                device: device,
                commandQueue: commandQueue,
                blurRadius: blurRadius,
                thresholdValue: thresholdValue,
                erosionKernel: erosionKernel,
                dilationKernel: dilationKernel,
                maxStars: maxStars,
                minDistancePct: minDistancePct,
                kNeighbors: kNeighbors,
                maxFWHMRatio: maxFWHMRatio
            )
            perFrame.append((quads: quads, stats: stats))
        }

        // Choose reference frame
        let refIdx: Int
        if referenceFrameParam >= 0 && referenceFrameParam < perFrame.count {
            refIdx = referenceFrameParam
        } else {
            refIdx = chooseBestFrame(perFrame.map { $0.stats })
        }
        Logger.processor.info("FrameRegistration: reference frame = \(refIdx)")

        // Equipment consistency check — runs before registration to give a clear early error
        try checkEquipmentConsistency(frames: frameSet.frames, referenceIndex: refIdx)

        // Build registration rows
        var rows: [RegistrationRow] = []
        let refQuads = perFrame[refIdx].quads

        for (i, frameData) in perFrame.enumerated() {
            if i == refIdx {
                rows.append(RegistrationRow(
                    frameIndex: i,
                    transform: .identity,
                    matchCount: frameData.quads.count,
                    rmse: 0,
                    stats: frameData.stats,
                    success: true
                ))
                continue
            }

            let (transform, matchCount, rmse, success) = computeTransform(
                reference: refQuads,
                target: frameData.quads,
                matchThreshold: matchThreshold,
                minMatches: minMatches,
                ransacIterations: ransacIterations,
                inlierThreshold: inlierThreshold,
                maxScaleDeviation: maxScaleDeviation,
                ratioThreshold: ratioThreshold
            )
            rows.append(RegistrationRow(
                frameIndex: i,
                transform: transform,
                matchCount: matchCount,
                rmse: rmse,
                stats: frameData.stats,
                success: success
            ))
        }

        // Check that enough frames were successfully registered
        let successCount = rows.filter { $0.success }.count
        let successRate  = Double(successCount) / Double(rows.count)
        if successRate < minSuccessRate {
            throw ProcessorExecutionError.executionFailed(
                buildRegistrationFailureMessage(
                    rows: rows,
                    successCount: successCount,
                    successRate: successRate,
                    minSuccessRate: minSuccessRate,
                    minMatches: minMatches
                )
            )
        }

        // Sort by frame index (reference may not be index 0)
        let sortedRows = rows.sorted { $0.frameIndex < $1.frameIndex }

        // ISO 8601 formatter for the timestamp column
        let iso8601Formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        // Build output DataFrame — metadata columns first, then analysis results
        var df = DataFrame()
        df.append(column: Column(name: "frame_index",
            contents: sortedRows.map { Int32($0.frameIndex) }))
        df.append(column: Column(name: "file_path",
            contents: sortedRows.map { frameSet.frames[$0.frameIndex].filePath ?? "" }))
        df.append(column: Column(name: "timestamp",
            contents: sortedRows.map { row -> String in
                guard let date = frameSet.frames[row.frameIndex].timestamp else { return "" }
                return iso8601Formatter.string(from: date)
            }))
        df.append(column: Column(name: "exposure",
            contents: sortedRows.map { frameSet.frames[$0.frameIndex].exposureTime } as [Double?]))
        df.append(column: Column(name: "filter",
            contents: sortedRows.map { row -> String in
                let frame = frameSet.frames[row.frameIndex]
                return frame.filterName ?? (frame.filter == .none ? "" : frame.filter.rawValue)
            }))
        df.append(column: Column(name: "gain",
            contents: sortedRows.map { frameSet.frames[$0.frameIndex].gain } as [Double?]))
        df.append(column: Column(name: "offset",
            contents: sortedRows.map { frameSet.frames[$0.frameIndex].offset } as [Double?]))
        df.append(column: Column(name: "frame_type",
            contents: sortedRows.map { frameSet.frames[$0.frameIndex].type.rawValue }))
        df.append(column: Column(name: "translation_x",
            contents: sortedRows.map { $0.transform.tx }))
        df.append(column: Column(name: "translation_y",
            contents: sortedRows.map { $0.transform.ty }))
        df.append(column: Column(name: "rotation_deg",
            contents: sortedRows.map { $0.transform.rotationDeg }))
        df.append(column: Column(name: "scale",
            contents: sortedRows.map { $0.transform.scale }))
        df.append(column: Column(name: "match_count",
            contents: sortedRows.map { Int32($0.matchCount) }))
        df.append(column: Column(name: "rmse",
            contents: sortedRows.map { $0.rmse }))
        df.append(column: Column(name: "registration_success",
            contents: sortedRows.map { Int32($0.success ? 1 : 0) }))
        df.append(column: Column(name: "star_count",
            contents: sortedRows.map { Int32($0.stats.starCount) }))
        df.append(column: Column(name: "mean_fwhm",
            contents: sortedRows.map { $0.stats.meanFWHM }))
        df.append(column: Column(name: "median_fwhm",
            contents: sortedRows.map { $0.stats.medianFWHM }))
        df.append(column: Column(name: "mean_eccentricity",
            contents: sortedRows.map { $0.stats.meanEccentricity }))
        df.append(column: Column(name: "mean_position_angle",
            contents: sortedRows.map { $0.stats.meanPositionAngle }))
        df.append(column: Column(name: "mean_flux",
            contents: sortedRows.map { $0.stats.meanFlux }))
        df.append(column: Column(name: "sky_background",
            contents: sortedRows.map { $0.stats.skyBackground }))
        df.append(column: Column(name: "sky_noise",
            contents: sortedRows.map { $0.stats.skyNoise }))

        guard var regTable = outputs["registration_table"] as? TableData else {
            throw ProcessorExecutionError.executionFailed("registration_table output not found")
        }
        regTable.dataFrame = df
        outputs["registration_table"] = regTable

        // Output reference star positions (only when the pipeline declares this output)
        if var refStarsTable = outputs["reference_stars"] as? TableData {
            let stars = uniqueStars(from: perFrame[refIdx].quads)
            var refDF = DataFrame()
            refDF.append(column: Column<Int>(name: "star_index", contents: stars.indices.map { Int($0) }))
            refDF.append(column: Column<Double>(name: "x", contents: stars.map { $0.x }))
            refDF.append(column: Column<Double>(name: "y", contents: stars.map { $0.y }))
            refStarsTable.dataFrame = refDF
            outputs["reference_stars"] = refStarsTable
        }
    }

    private func uniqueStars(from quads: [QuadDescriptor], dedupeRadius: Double = 2.0) -> [(x: Double, y: Double)] {
        var result: [(x: Double, y: Double)] = []
        for quad in quads {
            for s in [quad.s1, quad.s2, quad.s3, quad.s4] {
                let dup = result.contains { dx, dy in
                    let ex = dx - s.x, ey = dy - s.y
                    return ex*ex + ey*ey < dedupeRadius*dedupeRadius
                }
                if !dup { result.append((s.x, s.y)) }
            }
        }
        return result
    }

    // MARK: - Equipment consistency check

    private func checkEquipmentConsistency(frames: [Frame], referenceIndex: Int) throws {
        let refFrame = frames[referenceIndex]
        let refWidth  = refFrame.texture?.width  ?? 0
        let refHeight = refFrame.texture?.height ?? 0
        let refScale  = refFrame.pixelScale

        var dimMismatches:   [(index: Int, width: Int, height: Int)] = []
        var scaleMismatches: [(index: Int, scale: Double)] = []

        for (i, frame) in frames.enumerated() where i != referenceIndex {
            let w = frame.texture?.width  ?? 0
            let h = frame.texture?.height ?? 0
            if w > 0 && h > 0 && refWidth > 0 && refHeight > 0 {
                if w != refWidth || h != refHeight {
                    dimMismatches.append((i, w, h))
                }
            }
            if let rps = refScale, let fps = frame.pixelScale, rps > 0 {
                if abs(rps - fps) / rps > 0.05 {
                    scaleMismatches.append((i, fps))
                }
            }
        }

        if !dimMismatches.isEmpty {
            let list = dimMismatches
                .map { "frame \($0.index): \($0.width)×\($0.height)" }
                .joined(separator: ", ")
            throw ProcessorExecutionError.executionFailed(
                "Equipment mismatch: the following frame(s) have different image dimensions " +
                "than the reference frame (\(refWidth)×\(refHeight) px): \(list). " +
                "Ensure all frames were captured with the same camera."
            )
        }

        if !scaleMismatches.isEmpty {
            let refStr  = refScale.map { String(format: "%.3f", $0) } ?? "unknown"
            let list = scaleMismatches
                .map { "frame \($0.index): \(String(format: "%.3f", $0.scale))\"/px" }
                .joined(separator: ", ")
            throw ProcessorExecutionError.executionFailed(
                "Equipment mismatch: the following frame(s) have a different pixel scale " +
                "than the reference frame (\(refStr)\"/px): \(list). " +
                "Ensure all frames were captured with the same telescope and camera combination."
            )
        }
    }

    // MARK: - Informative failure message

    private func buildRegistrationFailureMessage(
        rows: [RegistrationRow],
        successCount: Int,
        successRate: Double,
        minSuccessRate: Double,
        minMatches: Int
    ) -> String {
        let total = rows.count
        let failed = rows.filter { !$0.success }
        let tooFewMatches = failed.filter { $0.matchCount < minMatches }.count
        let badScale      = failed.filter { $0.matchCount >= minMatches }.count

        var msg = String(
            format: "Registration failed: only %d of %d frames (%.0f%%) were successfully registered " +
                    "(minimum required: %.0f%%). ",
            successCount, total, successRate * 100, minSuccessRate * 100
        )

        if tooFewMatches > 0 && badScale > 0 {
            msg += "\(tooFewMatches) frame(s) had too few star matches and \(badScale) frame(s) had " +
                   "an incorrect computed scale — suggesting a sparse star field with false quad matches. "
        } else if badScale > 0 {
            msg += "\(badScale) frame(s) had sufficient star matches but the computed scale deviated " +
                   "from 1.0, indicating false quad matches rather than a true alignment. " +
                   "This is a known failure mode of quad-based registration in sparse fields. "
        } else {
            msg += "\(tooFewMatches) frame(s) had too few star matches — the star field is too sparse " +
                   "for the quad-matching algorithm to find reliable correspondences. "
        }

        msg += "Consider one of these alternatives better suited to sparse fields: " +
               "(1) Phase-correlation registration — works without star detection, uses pixel-level " +
               "cross-correlation; translation-only but robust to very low star counts. " +
               "(2) Plate-solving registration (e.g. ASTAP or Astrometry.net) — matches stars against " +
               "a catalog and is reliable with as few as 6–10 stars. " +
               "(3) Manual reference-point registration — specify 2–3 star coordinates per frame manually."

        return msg
    }

    // MARK: - Star detection sub-pipeline

    private func detectStarsAndQuads(
        frame: Frame,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        blurRadius: Double,
        thresholdValue: Double,
        erosionKernel: Int,
        dilationKernel: Int,
        maxStars: Int,
        minDistancePct: Double,
        kNeighbors: Int,
        maxFWHMRatio: Double
    ) throws -> (quads: [QuadDescriptor], stats: FrameStats) {
        // Helpers to run a processor and extract output frame/table
        func runFrame(_ processor: any Processor, inputs: [String: ProcessData], outputKey: String, params: [String: Parameter] = [:]) throws -> Frame {
            var placeholder: [String: ProcessData] = [outputKey: emptyFrame()]
            try processor.execute(inputs: inputs, outputs: &placeholder, parameters: params, device: device, commandQueue: commandQueue)
            guard let f = placeholder[outputKey] as? Frame else {
                throw ProcessorExecutionError.executionFailed("\(processor.id): missing output '\(outputKey)'")
            }
            return f
        }

        func runTable(_ processor: any Processor, inputs: [String: ProcessData], outputKey: String, params: [String: Parameter] = [:]) throws -> TableData {
            let keys = ["pixel_coordinates", "quads", "median_fwhm", "background_level",
                        "background_frame", "background_subtracted_frame", "blurred_frame",
                        "grayscale_frame", "thresholded_frame", "eroded_frame", "dilated_frame"]
            var placeholder: [String: ProcessData] = [:]
            for k in keys { placeholder[k] = TableData() }
            try processor.execute(inputs: inputs, outputs: &placeholder, parameters: params, device: device, commandQueue: commandQueue)
            guard let t = placeholder[outputKey] as? TableData else {
                throw ProcessorExecutionError.executionFailed("\(processor.id): missing output '\(outputKey)'")
            }
            return t
        }

        // 1. Grayscale
        let gray = try runFrame(GrayscaleProcessor(), inputs: ["input_frame": frame], outputKey: "grayscale_frame")

        // 2. Blur
        let blurred = try runFrame(
            GaussianBlurProcessor(),
            inputs: ["input_frame": gray],
            outputKey: "blurred_frame",
            params: ["radius": .double(blurRadius)]
        )

        // 3. Background estimation (for subtracted frame)
        var bgOutputs: [String: ProcessData] = [
            "background_frame": emptyFrame(),
            "background_subtracted_frame": emptyFrame(),
            "background_level": TableData()
        ]
        try BackgroundEstimationProcessor().execute(
            inputs: ["input_frame": blurred],
            outputs: &bgOutputs,
            parameters: [:],
            device: device,
            commandQueue: commandQueue
        )
        guard let bgSubtracted = bgOutputs["background_subtracted_frame"] as? Frame else {
            throw ProcessorExecutionError.executionFailed("BackgroundEstimation: missing background_subtracted_frame")
        }

        // 4. Threshold
        let thresholded = try runFrame(
            ThresholdProcessor(),
            inputs: ["input_frame": bgSubtracted],
            outputKey: "thresholded_frame",
            params: ["threshold_value": .double(thresholdValue), "method": .string("sigma")]
        )

        // 5. Erosion
        let eroded = try runFrame(
            ErosionProcessor(),
            inputs: ["input_frame": thresholded],
            outputKey: "eroded_frame",
            params: ["kernel_size": .int(erosionKernel)]
        )

        // 6. Dilation
        let dilated = try runFrame(
            DilationProcessor(),
            inputs: ["input_frame": eroded],
            outputKey: "dilated_frame",
            params: ["kernel_size": .int(dilationKernel)]
        )

        // 7. Connected components
        var ccOutputs: [String: ProcessData] = ["pixel_coordinates": TableData()]
        try ConnectedComponentsProcessor().execute(
            inputs: ["input_frame": dilated],
            outputs: &ccOutputs,
            parameters: [:],
            device: device,
            commandQueue: commandQueue
        )
        guard let ccTable = ccOutputs["pixel_coordinates"] as? TableData else {
            throw ProcessorExecutionError.executionFailed("ConnectedComponents: missing pixel_coordinates")
        }

        // 8. FWHM
        var fwhmOutputs: [String: ProcessData] = [
            "pixel_coordinates": TableData(),
            "median_fwhm": TableData()
        ]
        try FWHMProcessor().execute(
            inputs: ["input_frame": bgSubtracted, "pixel_coordinates": ccTable],
            outputs: &fwhmOutputs,
            parameters: [:],
            device: device,
            commandQueue: commandQueue
        )
        guard let rawStarsTable = fwhmOutputs["pixel_coordinates"] as? TableData else {
            throw ProcessorExecutionError.executionFailed("FWHM: missing pixel_coordinates")
        }

        // Filter out extended sources (nebula blobs, diffuse gradients) that the star
        // detector picks up but that are not point sources. Done after FWHM so we have
        // reliable size measurements. The filtered table is used for both quad generation
        // and quality stats, so star_count reflects real point sources only.
        let starsTable = maxFWHMRatio > 0
            ? filterStarsByFWHM(rawStarsTable, maxFWHMRatio: maxFWHMRatio)
            : rawStarsTable

        // 9. Quads
        var quadsOutputs: [String: ProcessData] = ["quads": TableData()]
        try QuadsProcessor().execute(
            inputs: ["pixel_coordinates": starsTable],
            outputs: &quadsOutputs,
            parameters: [
                "max_stars": .int(maxStars),
                "min_distance_percent": .double(minDistancePct),
                "k_neighbors": .int(kNeighbors)
            ],
            device: device,
            commandQueue: commandQueue
        )
        guard let quadsTable = quadsOutputs["quads"] as? TableData else {
            throw ProcessorExecutionError.executionFailed("Quads: missing quads")
        }

        // Sky background from background estimation, converted from normalized [0,1] to ADU.
        let skyBackgroundNorm = (bgOutputs["background_level"] as? TableData)?
            .dataFrame?.rows.first?["background_level"] as? Double ?? 0.0
        let skyBackground = frame.toADU(skyBackgroundNorm) ?? skyBackgroundNorm

        // Sky noise: Poisson shot-noise model — √(net sky above bias).
        // Pixel-level NMAD converges to the same value across frames when conditions are
        // stable (read-noise dominated), because all frames share the same normalisation
        // range and the ADU noise barely changes. The Poisson model uses sky_background
        // directly, which does vary per frame, giving genuinely different per-frame values
        // that scale correctly when compared to the stacked noise (σ_stack ≈ σ_frame / √N).
        let biasADU = frame.offset ?? 0.0
        let skyNoise = sqrt(max(0.0, skyBackground - biasADU))

        let quads = extractQuadDescriptors(from: quadsTable)
        let stats = extractStats(from: starsTable, skyBackground: skyBackground, skyNoise: skyNoise)
        return (quads: quads, stats: stats)
    }

    // MARK: - Extended-source filter

    /// Removes sources whose average FWHM exceeds `maxFWHMRatio` × the per-frame median FWHM.
    /// Rejects nebula blobs, diffuse emission edges, and other non-stellar detections that
    /// corrupt quad descriptors and cause false matches in sparse fields.
    private func filterStarsByFWHM(_ table: TableData, maxFWHMRatio: Double) -> TableData {
        guard let df = table.dataFrame, !df.rows.isEmpty else { return table }

        // Compute average FWHM per row
        var avgFWHMs = [Double](repeating: 0.0, count: df.rows.count)
        for (i, row) in df.rows.enumerated() {
            let maj = (row["fwhm_major"] as? Double) ?? 0
            let min = (row["fwhm_minor"] as? Double) ?? 0
            avgFWHMs[i] = (maj + min) / 2.0
        }

        let med = median(avgFWHMs.filter { $0 > 0 })
        guard med > 0 else { return table }
        let maxAllowed = maxFWHMRatio * med

        let validIndices = avgFWHMs.indices.filter { avgFWHMs[$0] <= maxAllowed }
        let removedCount = df.rows.count - validIndices.count
        guard removedCount > 0 else { return table }

        Logger.processor.info("FrameRegistration: FWHM filter removed \(removedCount) extended source(s) (threshold: \(maxAllowed, format: .fixed(precision: 1)) px, median: \(med, format: .fixed(precision: 1)) px)")

        // Detect which optional columns are present
        let hasSaturated    = df.columns.contains { $0.name == "saturated" }
        let hasMajorAxis    = df.columns.contains { $0.name == "major_axis" }
        let hasMinorAxis    = df.columns.contains { $0.name == "minor_axis" }
        let hasEccentricity = df.columns.contains { $0.name == "eccentricity" }
        let hasRotAngle     = df.columns.contains { $0.name == "rotation_angle" }

        // Accumulate typed values for each valid row
        var ids:       [Int]    = []; ids.reserveCapacity(validIndices.count)
        var areas:     [Int]    = []; areas.reserveCapacity(validIndices.count)
        var fluxes:    [Double] = []; fluxes.reserveCapacity(validIndices.count)
        var centXs:    [Double] = []; centXs.reserveCapacity(validIndices.count)
        var centYs:    [Double] = []; centYs.reserveCapacity(validIndices.count)
        var fwhmMajs:  [Double] = []; fwhmMajs.reserveCapacity(validIndices.count)
        var fwhmMins:  [Double] = []; fwhmMins.reserveCapacity(validIndices.count)
        var sats:      [Bool]   = []; sats.reserveCapacity(validIndices.count)
        var majAxes:   [Double] = []; majAxes.reserveCapacity(validIndices.count)
        var minAxes:   [Double] = []; minAxes.reserveCapacity(validIndices.count)
        var eccs:      [Double] = []; eccs.reserveCapacity(validIndices.count)
        var rotAngles: [Double] = []; rotAngles.reserveCapacity(validIndices.count)

        for i in validIndices {
            let row = df.rows[i]
            ids.append((row["id"] as? Int) ?? i)
            areas.append((row["area"] as? Int) ?? 0)
            fluxes.append((row["flux"] as? Double) ?? 0)
            centXs.append((row["centroid_x"] as? Double) ?? 0)
            centYs.append((row["centroid_y"] as? Double) ?? 0)
            fwhmMajs.append((row["fwhm_major"] as? Double) ?? 0)
            fwhmMins.append((row["fwhm_minor"] as? Double) ?? 0)
            if hasSaturated    { sats.append((row["saturated"] as? Bool) ?? false) }
            if hasMajorAxis    { majAxes.append((row["major_axis"] as? Double) ?? 0) }
            if hasMinorAxis    { minAxes.append((row["minor_axis"] as? Double) ?? 0) }
            if hasEccentricity { eccs.append((row["eccentricity"] as? Double) ?? 0) }
            if hasRotAngle     { rotAngles.append((row["rotation_angle"] as? Double) ?? 0) }
        }

        var newDF = DataFrame()
        newDF.append(column: Column(name: "id",         contents: ids))
        newDF.append(column: Column(name: "area",       contents: areas))
        newDF.append(column: Column(name: "flux",       contents: fluxes))
        newDF.append(column: Column(name: "centroid_x", contents: centXs))
        newDF.append(column: Column(name: "centroid_y", contents: centYs))
        newDF.append(column: Column(name: "fwhm_major", contents: fwhmMajs))
        newDF.append(column: Column(name: "fwhm_minor", contents: fwhmMins))
        if hasSaturated    { newDF.append(column: Column(name: "saturated",      contents: sats)) }
        if hasMajorAxis    { newDF.append(column: Column(name: "major_axis",     contents: majAxes)) }
        if hasMinorAxis    { newDF.append(column: Column(name: "minor_axis",     contents: minAxes)) }
        if hasEccentricity { newDF.append(column: Column(name: "eccentricity",   contents: eccs)) }
        if hasRotAngle     { newDF.append(column: Column(name: "rotation_angle", contents: rotAngles)) }

        var result = table
        result.dataFrame = newDF
        return result
    }

    private func emptyFrame() -> Frame {
        Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float,
              texture: nil, outputProcess: nil, inputProcesses: [])
    }

    // MARK: - Quad extraction

    private func extractQuadDescriptors(from table: TableData) -> [QuadDescriptor] {
        guard let df = table.dataFrame else { return [] }
        var result: [QuadDescriptor] = []
        for row in df.rows {
            guard
                let dx3 = row["descriptor_x3"] as? Double,
                let dy3 = row["descriptor_y3"] as? Double,
                let dx4 = row["descriptor_x4"] as? Double,
                let dy4 = row["descriptor_y4"] as? Double,
                let s1x = row["s1_x"] as? Double, let s1y = row["s1_y"] as? Double,
                let s2x = row["s2_x"] as? Double, let s2y = row["s2_y"] as? Double,
                let s3x = row["s3_x"] as? Double, let s3y = row["s3_y"] as? Double,
                let s4x = row["s4_x"] as? Double, let s4y = row["s4_y"] as? Double
            else { continue }
            result.append(QuadDescriptor(
                dx3: dx3, dy3: dy3, dx4: dx4, dy4: dy4,
                s1: StarPoint(x: s1x, y: s1y),
                s2: StarPoint(x: s2x, y: s2y),
                s3: StarPoint(x: s3x, y: s3y),
                s4: StarPoint(x: s4x, y: s4y)
            ))
        }
        return result
    }

    // MARK: - Quality stats extraction

    private func extractStats(from table: TableData, skyBackground: Double = 0, skyNoise: Double = 0) -> FrameStats {
        guard let df = table.dataFrame, !df.rows.isEmpty else {
            return FrameStats(starCount: 0, meanFWHM: 0, medianFWHM: 0, meanEccentricity: 0, meanPositionAngle: 0, meanFlux: 0, skyBackground: 0, skyNoise: 0)
        }
        var fwhmValues: [Double] = []
        var eccValues: [Double] = []
        var paValues: [Double] = []
        var fluxValues: [Double] = []

        for row in df.rows {
            let fmaj = (row["fwhm_major"] as? Double) ?? 0
            let fmin = (row["fwhm_minor"] as? Double) ?? 0
            fwhmValues.append((fmaj + fmin) / 2.0)
            if let ecc = row["eccentricity"] as? Double { eccValues.append(ecc) }
            if let pa  = row["rotation_angle"] as? Double { paValues.append(pa * 180.0 / .pi) }
            if let flux = row["flux"] as? Double { fluxValues.append(flux) }
        }

        let meanFWHM = fwhmValues.isEmpty ? 0 : fwhmValues.reduce(0, +) / Double(fwhmValues.count)
        let medianFWHM = median(fwhmValues)
        let meanEcc = eccValues.isEmpty ? 0 : eccValues.reduce(0, +) / Double(eccValues.count)
        let meanPA  = paValues.isEmpty  ? 0 : paValues.reduce(0, +) / Double(paValues.count)
        let meanFlux = fluxValues.isEmpty ? 0 : fluxValues.reduce(0, +) / Double(fluxValues.count)

        return FrameStats(
            starCount: df.rows.count,
            meanFWHM: meanFWHM,
            medianFWHM: medianFWHM,
            meanEccentricity: meanEcc,
            meanPositionAngle: meanPA,
            meanFlux: meanFlux,
            skyBackground: skyBackground,
            skyNoise: skyNoise
        )
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Two-step NMAD from four 128×128 corner crops: σ = 1.4826 × median(|x − median(x)|).
    /// Must be called on the original (pre-subtraction) texture to avoid the clamp-to-zero
    /// artefact. Sampling corners rather than the centre avoids bias from the target object.
    /// Returns the minimum NMAD across all four corners (most sky-like region wins).
    private func computeNMAD(
        from texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> Double {
        let w = texture.width, h = texture.height
        let cw = min(w / 4, 128)
        let ch = min(h / 4, 128)
        guard cw > 0, ch > 0 else { return 0.0 }

        // Four corner origins
        let origins = [
            MTLOrigin(x: 0,         y: 0,         z: 0),
            MTLOrigin(x: w - cw,    y: 0,         z: 0),
            MTLOrigin(x: 0,         y: h - ch,    z: 0),
            MTLOrigin(x: w - cw,    y: h - ch,    z: 0),
        ]

        let bytesPerRow = cw * MemoryLayout<Float32>.size
        let bufferSize  = bytesPerRow * ch

        var minNMAD = Double.infinity
        for origin in origins {
            guard let buf = device.makeBuffer(length: bufferSize, options: .storageModeShared),
                  let cmdBuf = commandQueue.makeCommandBuffer(),
                  let blit = cmdBuf.makeBlitCommandEncoder() else { continue }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: origin,
                      sourceSize: MTLSize(width: cw, height: ch, depth: 1),
                      to: buf, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bufferSize)
            blit.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()

            let count = cw * ch
            let ptr   = buf.contents().bindMemory(to: Float32.self, capacity: count)
            var sample = [Double](repeating: 0, count: count)
            for i in 0 ..< count { sample[i] = Double(ptr[i]) }
            sample.sort()
            let med = sample[count / 2]
            var devs = [Double](repeating: 0, count: count)
            for i in 0 ..< count { devs[i] = abs(sample[i] - med) }
            devs.sort()
            let nmad = 1.4826 * devs[count / 2]
            if nmad < minNMAD { minNMAD = nmad }
        }
        return minNMAD == .infinity ? 0.0 : minNMAD
    }

    // MARK: - Reference frame selection

    private func chooseBestFrame(_ stats: [FrameStats]) -> Int {
        // Best = most stars, then lowest mean FWHM
        var bestIdx = 0
        var bestScore = -Double.infinity
        for (i, s) in stats.enumerated() {
            let score = Double(s.starCount) - (s.medianFWHM > 0 ? s.medianFWHM / 10.0 : 0)
            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Transform computation

    private func computeTransform(
        reference: [QuadDescriptor],
        target: [QuadDescriptor],
        matchThreshold: Double,
        minMatches: Int,
        ransacIterations: Int,
        inlierThreshold: Double,
        maxScaleDeviation: Double,
        ratioThreshold: Double
    ) -> (transform: SimilarityTransform, matchCount: Int, rmse: Double, success: Bool) {
        let matches = matchQuads(
            reference: reference,
            target: target,
            threshold: matchThreshold,
            ratioThreshold: ratioThreshold
        )
        guard matches.count >= minMatches else {
            Logger.processor.warning("FrameRegistration: only \(matches.count) quad matches (need \(minMatches)) — using identity")
            return (.identity, matches.count, 0, false)
        }

        // Build all point correspondences: 4 pairs per matched quad
        var pairs: [(ref: StarPoint, tgt: StarPoint)] = []
        for (refQ, tgtQ) in matches {
            pairs.append((ref: refQ.s1, tgt: tgtQ.s1))
            pairs.append((ref: refQ.s2, tgt: tgtQ.s2))
            pairs.append((ref: refQ.s3, tgt: tgtQ.s3))
            pairs.append((ref: refQ.s4, tgt: tgtQ.s4))
        }

        // Scale-constrained RANSAC
        let (bestInliers, _) = ransac(
            pairs: pairs,
            iterations: ransacIterations,
            inlierThreshold: inlierThreshold,
            maxScaleDeviation: maxScaleDeviation
        )

        let transform: SimilarityTransform
        let rmse: Double
        if bestInliers.count >= 4 {
            (transform, rmse) = leastSquaresSimilarity(pairs: bestInliers)
        } else {
            (transform, rmse) = leastSquaresSimilarity(pairs: pairs)
        }

        // Final scale sanity check — catches fallback path where RANSAC found no valid consensus
        guard abs(transform.scale - 1.0) <= maxScaleDeviation else {
            Logger.processor.warning("FrameRegistration: frame rejected — computed scale \(transform.scale, format: .fixed(precision: 4)) deviates from 1.0 by more than \(maxScaleDeviation); likely a false-match consensus")
            return (.identity, matches.count, rmse, false)
        }

        return (transform: transform, matchCount: matches.count, rmse: rmse, success: true)
    }

    // MARK: - Quad matching with ratio test and mutual cross-check

    private func matchQuads(
        reference: [QuadDescriptor],
        target: [QuadDescriptor],
        threshold: Double,
        ratioThreshold: Double
    ) -> [(QuadDescriptor, QuadDescriptor)] {
        guard !reference.isEmpty, !target.isEmpty else { return [] }

        // Forward pass: for each target quad track its best and second-best reference match
        var fwdBestIdx  = [Int](repeating: -1,        count: target.count)
        var fwdBestDist = [Double](repeating: .infinity, count: target.count)
        var fwdSecDist  = [Double](repeating: .infinity, count: target.count)

        for (ti, tq) in target.enumerated() {
            for (ri, rq) in reference.enumerated() {
                let d = descriptorDistance(tq, rq)
                if d < fwdBestDist[ti] {
                    fwdSecDist[ti]  = fwdBestDist[ti]
                    fwdBestDist[ti] = d
                    fwdBestIdx[ti]  = ri
                } else if d < fwdSecDist[ti] {
                    fwdSecDist[ti] = d
                }
            }
        }

        // Backward pass: for each reference quad find the best target match
        var bwdBestIdx  = [Int](repeating: -1,        count: reference.count)
        var bwdBestDist = [Double](repeating: .infinity, count: reference.count)

        for (ti, tq) in target.enumerated() {
            for (ri, rq) in reference.enumerated() {
                let d = descriptorDistance(tq, rq)
                if d < bwdBestDist[ri] {
                    bwdBestDist[ri] = d
                    bwdBestIdx[ri]  = ti
                }
            }
        }

        var matches: [(QuadDescriptor, QuadDescriptor)] = []
        for (ti, tq) in target.enumerated() {
            let ri = fwdBestIdx[ti]
            guard ri >= 0, fwdBestDist[ti] < threshold else { continue }
            // Lowe's ratio test: reject if second-best is nearly as good (ambiguous match)
            if fwdSecDist[ti] < .infinity && fwdBestDist[ti] / fwdSecDist[ti] >= ratioThreshold { continue }
            // Mutual cross-check: only keep if the reference quad's best match is also this target quad
            guard bwdBestIdx[ri] == ti else { continue }
            matches.append((reference[ri], tq))
        }
        return matches
    }

    private func descriptorDistance(_ a: QuadDescriptor, _ b: QuadDescriptor) -> Double {
        let d3x = a.dx3 - b.dx3
        let d3y = a.dy3 - b.dy3
        let d4x = a.dx4 - b.dx4
        let d4y = a.dy4 - b.dy4
        return sqrt(d3x*d3x + d3y*d3y + d4x*d4x + d4y*d4y)
    }

    // MARK: - Scale-constrained RANSAC

    private func ransac(
        pairs: [(ref: StarPoint, tgt: StarPoint)],
        iterations: Int,
        inlierThreshold: Double,
        maxScaleDeviation: Double
    ) -> (inliers: [(ref: StarPoint, tgt: StarPoint)], transform: SimilarityTransform) {
        guard pairs.count >= 4 else { return (pairs, .identity) }

        var bestInliers: [(ref: StarPoint, tgt: StarPoint)] = []
        var bestTransform = SimilarityTransform.identity

        for _ in 0..<iterations {
            // Sample 4 random pairs
            var sample: [(ref: StarPoint, tgt: StarPoint)] = []
            var indices = Array(0..<pairs.count)
            for _ in 0..<4 {
                let i = Int.random(in: 0..<indices.count)
                sample.append(pairs[indices[i]])
                indices.remove(at: i)
            }

            let (candidate, _) = leastSquaresSimilarity(pairs: sample)

            // Reject candidates that imply a physically impossible scale for same-equipment frames
            guard abs(candidate.scale - 1.0) <= maxScaleDeviation else { continue }

            let inliers = pairs.filter { residual(candidate, ref: $0.ref, tgt: $0.tgt) < inlierThreshold }

            if inliers.count > bestInliers.count {
                bestInliers   = inliers
                bestTransform = candidate
            }
        }

        return (bestInliers, bestTransform)
    }

    private func residual(_ t: SimilarityTransform, ref: StarPoint, tgt: StarPoint) -> Double {
        // Apply t to ref and compare with tgt
        let cosA = t.scale * cos(t.rotation)
        let sinA = t.scale * sin(t.rotation)
        let px = cosA * ref.x - sinA * ref.y + t.tx
        let py = sinA * ref.x + cosA * ref.y + t.ty
        let dx = px - tgt.x
        let dy = py - tgt.y
        return sqrt(dx*dx + dy*dy)
    }

    // MARK: - Least-squares similarity transform
    // x' = a*x - b*y + tx,  y' = b*x + a*y + ty
    // where a = scale*cos(θ), b = scale*sin(θ)

    private func leastSquaresSimilarity(
        pairs: [(ref: StarPoint, tgt: StarPoint)]
    ) -> (SimilarityTransform, Double) {
        guard pairs.count >= 2 else { return (.identity, 0) }

        let n = pairs.count
        // Build normal equations for [a, b, tx, ty]:
        //   AtA (4×4) x = Atb (4)
        // Row for x': [xi, -yi, 1, 0]
        // Row for y': [yi,  xi, 0, 1]
        var AtA = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var Atb = [Double](repeating: 0, count: 4)

        for (ref, tgt) in pairs {
            let x = ref.x, y = ref.y
            let xp = tgt.x, yp = tgt.y
            // Rows: rx = [x, -y, 1, 0], ry = [y, x, 0, 1]
            let rx: [Double] = [x, -y, 1, 0]
            let ry: [Double] = [y, x, 0, 1]
            for i in 0..<4 {
                for j in 0..<4 {
                    AtA[i][j] += rx[i]*rx[j] + ry[i]*ry[j]
                }
                Atb[i] += rx[i]*xp + ry[i]*yp
            }
        }

        guard let sol = solve4x4(matrix: AtA, rhs: Atb) else { return (.identity, 0) }
        let a = sol[0], b = sol[1], tx = sol[2], ty = sol[3]
        let scale = sqrt(a*a + b*b)
        let theta = atan2(b, a)

        // RMSE
        var sse = 0.0
        for (ref, tgt) in pairs {
            let px = a * ref.x - b * ref.y + tx
            let py = b * ref.x + a * ref.y + ty
            let dx = px - tgt.x, dy = py - tgt.y
            sse += dx*dx + dy*dy
        }
        let rmse = sqrt(sse / Double(n))

        return (SimilarityTransform(tx: tx, ty: ty, rotation: theta, scale: scale), rmse)
    }

    // MARK: - 4×4 Gaussian elimination

    private func solve4x4(matrix: [[Double]], rhs: [Double]) -> [Double]? {
        var A = matrix
        var b = rhs
        let n = 4

        for col in 0..<n {
            // Partial pivot
            var maxRow = col
            for row in (col+1)..<n {
                if abs(A[row][col]) > abs(A[maxRow][col]) { maxRow = row }
            }
            A.swapAt(col, maxRow)
            b.swapAt(col, maxRow)

            guard abs(A[col][col]) > 1e-12 else { return nil }

            for row in (col+1)..<n {
                let factor = A[row][col] / A[col][col]
                for j in col..<n { A[row][j] -= factor * A[col][j] }
                b[row] -= factor * b[col]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n-1, through: 0, by: -1) {
            x[i] = b[i]
            for j in (i+1)..<n { x[i] -= A[i][j] * x[j] }
            x[i] /= A[i][i]
        }
        return x
    }
}
