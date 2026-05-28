import Foundation
import Metal
import TabularData
import os

// MARK: - Shared value types

/// A single detected star's pixel position.
struct StarPoint {
    // swiftlint:disable identifier_name
    let x: Double
    let y: Double
    // swiftlint:enable identifier_name
}

/// A 2-D similarity transform: x' = scale·cos θ·x − scale·sin θ·y + tx
///                              y' = scale·sin θ·x + scale·cos θ·y + ty
struct SimilarityTransform {
    let tx: Double       // translation in x (pixels)
    let ty: Double       // translation in y (pixels)
    let rotation: Double // radians
    let scale: Double    // uniform scale factor (1.0 = same equipment)

    var rotationDeg: Double { rotation * 180.0 / .pi }

    static let identity = SimilarityTransform(tx: 0, ty: 0, rotation: 0, scale: 1)

    /// Decomposed form used by GPU/CPU warp kernels: x' = a·x − b·y + tx
    var a: Double { scale * cos(rotation) }
    var b: Double { scale * sin(rotation) }
}

/// Per-frame star quality statistics produced after source detection.
struct FrameStats {
    let starCount: Int
    let meanFWHM: Double
    let medianFWHM: Double
    let meanEccentricity: Double
    let meanPositionAngle: Double  // degrees
    let meanFlux: Double
    let skyBackground: Double      // estimated sky level (ADU)
    let skyNoise: Double           // Poisson √(sky − bias) (ADU)
}

// MARK: - Shared registration utilities

/// Internal namespace for utilities shared by all registration processors.
/// Not part of the public API.
enum RegistrationCore {

    // MARK: - Star detection sub-pipeline

    /// Runs the full star detection sub-pipeline on a single frame, through FWHM measurement
    /// and extended-source filtering, and returns the cleaned star table together with the
    /// sky background and noise estimates.
    ///
    /// The returned `starsTable` is ready to be passed directly to quad or triangle formation.
    static func detectStars(
        frame: Frame,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        blurRadius: Double,
        thresholdValue: Double,
        erosionKernel: Int,
        dilationKernel: Int,
        maxFWHMRatio: Double,
        maxEccentricity: Double = 0.0
    ) throws -> (starsTable: TableData, skyBackground: Double, skyNoise: Double) {

        // 1. Grayscale
        let gray = try runFrame(GrayscaleProcessor(),
                                inputs: ["input_frame": frame],
                                outputKey: "grayscale_frame",
                                device: device, commandQueue: commandQueue)

        // 2. Blur
        let blurred = try runFrame(GaussianBlurProcessor(),
                                   inputs: ["input_frame": gray],
                                   outputKey: "blurred_frame",
                                   params: ["radius": .double(blurRadius)],
                                   device: device, commandQueue: commandQueue)

        // 3. Background estimation
        var bgOutputs: [String: ProcessData] = [
            "background_frame": emptyFrame(),
            "background_subtracted_frame": emptyFrame(),
            "background_level": TableData()
        ]
        try BackgroundEstimationProcessor().execute(
            inputs: ["input_frame": blurred],
            outputs: &bgOutputs,
            parameters: [:],
            device: device, commandQueue: commandQueue
        )
        guard let bgSubtracted = bgOutputs["background_subtracted_frame"] as? Frame else {
            throw ProcessorExecutionError.executionFailed("BackgroundEstimation: missing background_subtracted_frame")
        }

        // 4. Threshold
        let thresholded = try runFrame(ThresholdProcessor(),
                                       inputs: ["input_frame": bgSubtracted],
                                       outputKey: "thresholded_frame",
                                       params: ["threshold_value": .double(thresholdValue),
                                                "method": .string("sigma")],
                                       device: device, commandQueue: commandQueue)

        // 5. Erosion
        let eroded = try runFrame(ErosionProcessor(),
                                  inputs: ["input_frame": thresholded],
                                  outputKey: "eroded_frame",
                                  params: ["kernel_size": .int(erosionKernel)],
                                  device: device, commandQueue: commandQueue)

        // 6. Dilation
        let dilated = try runFrame(DilationProcessor(),
                                   inputs: ["input_frame": eroded],
                                   outputKey: "dilated_frame",
                                   params: ["kernel_size": .int(dilationKernel)],
                                   device: device, commandQueue: commandQueue)

        // 7. Connected components
        var ccOutputs: [String: ProcessData] = ["pixel_coordinates": TableData()]
        try ConnectedComponentsProcessor().execute(
            inputs: ["input_frame": dilated],
            outputs: &ccOutputs,
            parameters: [:],
            device: device, commandQueue: commandQueue
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
            device: device, commandQueue: commandQueue
        )
        guard let rawStarsTable = fwhmOutputs["pixel_coordinates"] as? TableData else {
            throw ProcessorExecutionError.executionFailed("FWHM: missing pixel_coordinates")
        }

        // Sky background (normalized → ADU)
        let skyBackgroundNorm = (bgOutputs["background_level"] as? TableData)?
            .dataFrame?.rows.first?["background_level"] as? Double ?? 0.0
        let skyBackground = frame.toADU(skyBackgroundNorm) ?? skyBackgroundNorm
        let biasADU  = frame.offset ?? 0.0
        let skyNoise = sqrt(max(0.0, skyBackground - biasADU))

        // Extended-source filter — removes nebula blobs / gradient edges before pattern matching.
        // Skipped when maxFWHMRatio == 0 (FWHM) or maxEccentricity == 0 (eccentricity).
        let starsTable = filterStars(rawStarsTable, maxFWHMRatio: maxFWHMRatio, maxEccentricity: maxEccentricity)

        return (starsTable: starsTable, skyBackground: skyBackground, skyNoise: skyNoise)
    }

    // MARK: - Extended-source filter

    /// Removes detections that fail the FWHM or eccentricity filter.
    ///
    /// - `maxFWHMRatio > 0`: rejects detections whose average FWHM exceeds `maxFWHMRatio × median FWHM`.
    /// - `maxEccentricity > 0`: rejects detections whose eccentricity exceeds `maxEccentricity` (0 = circle, 1 = line).
    ///
    /// Either filter can be disabled independently by passing 0.
    static func filterStars(_ table: TableData, maxFWHMRatio: Double, maxEccentricity: Double = 0.0) -> TableData {
        guard let df = table.dataFrame, !df.rows.isEmpty else { return table }

        var avgFWHMs = [Double](repeating: 0.0, count: df.rows.count)
        for (i, row) in df.rows.enumerated() {
            let maj = (row["fwhm_major"] as? Double) ?? 0
            let min = (row["fwhm_minor"] as? Double) ?? 0
            avgFWHMs[i] = (maj + min) / 2.0
        }

        let maxAllowed: Double
        if maxFWHMRatio > 0 {
            let med = median(avgFWHMs.filter { $0 > 0 })
            maxAllowed = med > 0 ? maxFWHMRatio * med : Double.infinity
        } else {
            maxAllowed = Double.infinity
        }

        let validIndices = avgFWHMs.indices.filter { i in
            let fwhmOk = avgFWHMs[i] <= maxAllowed
            let eccOk: Bool
            if maxEccentricity > 0, let ecc = df.rows[i]["eccentricity"] as? Double {
                eccOk = ecc <= maxEccentricity
            } else {
                eccOk = true
            }
            return fwhmOk && eccOk
        }

        let removedCount = df.rows.count - validIndices.count
        guard removedCount > 0 else { return table }

        Logger.processor.info("RegistrationCore: source filter removed \(removedCount) source(s) (FWHM threshold: \(maxAllowed == .infinity ? "off" : String(format: "%.1f", maxAllowed)) px, eccentricity threshold: \(maxEccentricity > 0 ? String(format: "%.2f", maxEccentricity) : "off"))")

        let hasSaturated    = df.columns.contains { $0.name == "saturated" }
        let hasMajorAxis    = df.columns.contains { $0.name == "major_axis" }
        let hasMinorAxis    = df.columns.contains { $0.name == "minor_axis" }
        let hasEccentricity = df.columns.contains { $0.name == "eccentricity" }
        let hasRotAngle     = df.columns.contains { $0.name == "rotation_angle" }

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

    // MARK: - Quality stats extraction

    /// Extracts per-frame star quality metrics from the FWHM-measured star table.
    static func extractStats(
        from table: TableData,
        skyBackground: Double = 0,
        skyNoise: Double = 0
    ) -> FrameStats {
        guard let df = table.dataFrame, !df.rows.isEmpty else {
            return FrameStats(starCount: 0, meanFWHM: 0, medianFWHM: 0,
                              meanEccentricity: 0, meanPositionAngle: 0,
                              meanFlux: 0, skyBackground: 0, skyNoise: 0)
        }
        var fwhmValues: [Double] = []
        var eccValues:  [Double] = []
        var paValues:   [Double] = []
        var fluxValues: [Double] = []

        for row in df.rows {
            let fmaj = (row["fwhm_major"] as? Double) ?? 0
            let fmin = (row["fwhm_minor"] as? Double) ?? 0
            fwhmValues.append((fmaj + fmin) / 2.0)
            if let ecc  = row["eccentricity"]   as? Double { eccValues.append(ecc) }
            if let pa   = row["rotation_angle"] as? Double { paValues.append(pa * 180.0 / .pi) }
            if let flux = row["flux"]           as? Double { fluxValues.append(flux) }
        }

        let meanFWHM  = fwhmValues.isEmpty ? 0 : fwhmValues.reduce(0, +) / Double(fwhmValues.count)
        let medFWHM   = median(fwhmValues)
        let meanEcc   = eccValues.isEmpty  ? 0 : eccValues.reduce(0,  +) / Double(eccValues.count)
        let meanPA    = paValues.isEmpty   ? 0 : paValues.reduce(0,   +) / Double(paValues.count)
        let meanFlux  = fluxValues.isEmpty ? 0 : fluxValues.reduce(0, +) / Double(fluxValues.count)

        return FrameStats(starCount: df.rows.count,
                          meanFWHM: meanFWHM, medianFWHM: medFWHM,
                          meanEccentricity: meanEcc, meanPositionAngle: meanPA,
                          meanFlux: meanFlux, skyBackground: skyBackground, skyNoise: skyNoise)
    }

    // MARK: - Reference frame selection

    /// Picks the frame with the best combined score (most stars + sharpest FWHM).
    static func chooseBestFrame(_ stats: [FrameStats]) -> Int {
        var bestIdx   = 0
        var bestScore = -Double.infinity
        for (i, s) in stats.enumerated() {
            let score = Double(s.starCount) - (s.medianFWHM > 0 ? s.medianFWHM / 10.0 : 0)
            if score > bestScore { bestScore = score; bestIdx = i }
        }
        return bestIdx
    }

    // MARK: - Equipment consistency check

    /// Verifies that all frames were captured with the same camera and optical system.
    /// Checks image dimensions (required) and pixel scale from the FITS header (when available).
    /// Throws a descriptive error if a mismatch is detected.
    static func checkEquipmentConsistency(frames: [Frame], referenceIndex: Int) throws {
        let refFrame  = frames[referenceIndex]
        let refWidth  = refFrame.texture?.width  ?? 0
        let refHeight = refFrame.texture?.height ?? 0
        let refScale  = refFrame.pixelScale

        var dimMismatches:   [(index: Int, width: Int, height: Int)] = []
        var scaleMismatches: [(index: Int, scale: Double)]           = []

        for (i, frame) in frames.enumerated() where i != referenceIndex {
            let w = frame.texture?.width  ?? 0
            let h = frame.texture?.height ?? 0
            if w > 0 && h > 0 && refWidth > 0 && refHeight > 0, w != refWidth || h != refHeight {
                dimMismatches.append((i, w, h))
            }
            if let rps = refScale, let fps = frame.pixelScale, rps > 0,
               abs(rps - fps) / rps > 0.05 {
                scaleMismatches.append((i, fps))
            }
        }

        if !dimMismatches.isEmpty {
            let list = dimMismatches.map { "frame \($0.index): \($0.width)×\($0.height)" }.joined(separator: ", ")
            throw ProcessorExecutionError.executionFailed(
                "Equipment mismatch: the following frame(s) have different image dimensions " +
                "than the reference frame (\(refWidth)×\(refHeight) px): \(list). " +
                "Ensure all frames were captured with the same camera."
            )
        }

        if !scaleMismatches.isEmpty {
            let refStr = refScale.map { String(format: "%.3f", $0) } ?? "unknown"
            let list   = scaleMismatches.map {
                "frame \($0.index): \(String(format: "%.3f", $0.scale))\"/px"
            }.joined(separator: ", ")
            throw ProcessorExecutionError.executionFailed(
                "Equipment mismatch: the following frame(s) have a different pixel scale " +
                "than the reference frame (\(refStr)\"/px): \(list). " +
                "Ensure all frames were captured with the same telescope and camera combination."
            )
        }
    }

    // MARK: - Success-rate error message

    /// Builds an informative error message when the registration success rate falls below
    /// the configured minimum. The message distinguishes between algorithm failure (too
    /// sparse for the pattern-matching method) and false-match failure (bad scale).
    static func buildRegistrationFailureMessage(
        successCount: Int,
        total: Int,
        successRate: Double,
        minSuccessRate: Double,
        tooFewMatchesCount: Int,
        badScaleCount: Int
    ) -> String {
        var msg = String(
            format: "Registration failed: only %d of %d frames (%.0f%%) were successfully registered " +
                    "(minimum required: %.0f%%). ",
            successCount, total, successRate * 100, minSuccessRate * 100
        )

        if tooFewMatchesCount > 0 && badScaleCount > 0 {
            msg += "\(tooFewMatchesCount) frame(s) had too few star matches and \(badScaleCount) frame(s) had " +
                   "an incorrect computed scale — suggesting a sparse star field with false pattern matches. "
        } else if badScaleCount > 0 {
            msg += "\(badScaleCount) frame(s) had sufficient star matches but the computed scale deviated " +
                   "from 1.0, indicating false pattern matches. " +
                   "This is a known failure mode of descriptor-based registration in sparse fields. "
        } else {
            msg += "\(tooFewMatchesCount) frame(s) had too few star matches — the star field is too sparse " +
                   "for the pattern-matching algorithm. "
        }

        msg += "Consider one of these alternatives better suited to sparse fields: " +
               "(1) Triangle registration (frame_registration_triangle pipeline) — uses 3-star patterns " +
               "for more pattern coverage from the same star count. " +
               "(2) Phase-correlation registration — works without star detection, uses pixel-level " +
               "cross-correlation; translation-only but robust to very low star counts. " +
               "(3) Plate-solving registration (e.g. ASTAP or Astrometry.net) — matches stars against " +
               "a catalog and is reliable with as few as 6–10 stars."
        return msg
    }

    /// Builds an informative error message for triangle registration failure.
    static func buildTriangleFailureMessage(
        successCount: Int,
        total: Int,
        successRate: Double,
        minSuccessRate: Double,
        tooFewMatchesCount: Int,
        badScaleCount: Int
    ) -> String {
        var msg = String(
            format: "Triangle registration failed: only %d of %d frames (%.0f%%) were successfully " +
                    "registered (minimum required: %.0f%%). ",
            successCount, total, successRate * 100, minSuccessRate * 100
        )

        if tooFewMatchesCount > 0 && badScaleCount > 0 {
            msg += "\(tooFewMatchesCount) frame(s) had too few triangle matches and " +
                   "\(badScaleCount) frame(s) had an incorrect computed scale. "
        } else if badScaleCount > 0 {
            msg += "\(badScaleCount) frame(s) had sufficient triangle matches but the computed " +
                   "scale deviated from 1.0, indicating false pattern matches. "
        } else {
            msg += "\(tooFewMatchesCount) frame(s) had too few triangle matches — " +
                   "the star field may be too sparse even for triangle-based registration. "
        }

        msg += "Consider phase-correlation registration (translation-only, no star detection required) " +
               "or plate-solving (e.g. ASTAP or Astrometry.net) for very sparse fields."
        return msg
    }

    /// Builds an informative error message for star-matching registration failure.
    static func buildStarMatchingFailureMessage(
        successCount: Int,
        total: Int,
        successRate: Double,
        minSuccessRate: Double,
        failedCount: Int
    ) -> String {
        var msg = String(
            format: "Star-matching registration failed: only %d of %d frames (%.0f%%) were " +
                    "successfully registered (minimum required: %.0f%%). ",
            successCount, total, successRate * 100, minSuccessRate * 100
        )
        msg += "\(failedCount) frame(s) had fewer than the required minimum of matched stars. "
        msg += "The field may be too sparse or the star detection threshold too strict. " +
               "Consider reducing threshold_value, increasing max_stars, or using " +
               "plate-solving (e.g. ASTAP or Astrometry.net)."
        return msg
    }

    // MARK: - Least-squares similarity transform
    // Solves: x' = a·x − b·y + tx,  y' = b·x + a·y + ty
    //         where a = scale·cos θ,  b = scale·sin θ

    /// Fits a similarity transform to a set of point correspondences using least squares.
    /// Returns the transform and its RMSE over the input pairs.
    static func leastSquaresSimilarity(
        pairs: [(ref: StarPoint, tgt: StarPoint)]
    ) -> (SimilarityTransform, Double) {
        guard pairs.count >= 2 else { return (.identity, 0) }
        let n = pairs.count
        var AtA = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var Atb = [Double](repeating: 0, count: 4)

        for (ref, tgt) in pairs {
            let x = ref.x, y = ref.y, xp = tgt.x, yp = tgt.y
            let rx: [Double] = [x, -y, 1, 0]
            let ry: [Double] = [y,  x, 0, 1]
            for i in 0..<4 {
                for j in 0..<4 { AtA[i][j] += rx[i]*rx[j] + ry[i]*ry[j] }
                Atb[i] += rx[i]*xp + ry[i]*yp
            }
        }

        guard let sol = solve4x4(matrix: AtA, rhs: Atb) else { return (.identity, 0) }
        let a = sol[0], b = sol[1], tx = sol[2], ty = sol[3]
        let scale = sqrt(a*a + b*b)
        let theta = atan2(b, a)

        var sse = 0.0
        for (ref, tgt) in pairs {
            let px = a*ref.x - b*ref.y + tx, py = b*ref.x + a*ref.y + ty
            sse += (px-tgt.x)*(px-tgt.x) + (py-tgt.y)*(py-tgt.y)
        }
        return (SimilarityTransform(tx: tx, ty: ty, rotation: theta, scale: scale),
                sqrt(sse / Double(n)))
    }

    // MARK: - Scale-constrained RANSAC

    /// Runs RANSAC to find the largest inlier set for a similarity transform.
    /// Candidates whose implied scale deviates from 1.0 by more than `maxScaleDeviation`
    /// are skipped — this is the key constraint that eliminates false-match consensuses.
    static func ransac(
        pairs: [(ref: StarPoint, tgt: StarPoint)],
        iterations: Int,
        inlierThreshold: Double,
        maxScaleDeviation: Double
    ) -> (inliers: [(ref: StarPoint, tgt: StarPoint)], transform: SimilarityTransform) {
        guard pairs.count >= 4 else { return (pairs, .identity) }

        var bestInliers:   [(ref: StarPoint, tgt: StarPoint)] = []
        var bestTransform = SimilarityTransform.identity

        for _ in 0..<iterations {
            var sample:  [(ref: StarPoint, tgt: StarPoint)] = []
            var indices = Array(0..<pairs.count)
            for _ in 0..<4 {
                let i = Int.random(in: 0..<indices.count)
                sample.append(pairs[indices[i]])
                indices.remove(at: i)
            }

            let (candidate, _) = leastSquaresSimilarity(pairs: sample)
            guard abs(candidate.scale - 1.0) <= maxScaleDeviation else { continue }

            let inliers = pairs.filter { residual(candidate, ref: $0.ref, tgt: $0.tgt) < inlierThreshold }
            if inliers.count > bestInliers.count {
                bestInliers   = inliers
                bestTransform = candidate
            }
        }
        return (bestInliers, bestTransform)
    }

    // MARK: - Direct star-position matching

    /// Finds the best similarity transform by exhaustive star-correspondence search.
    ///
    /// For every possible (refStar, tgtStar) pairing, treats the implied translation
    /// as a candidate and counts how many other reference stars map within
    /// `inlierThreshold` pixels of any target star. The candidate with the most
    /// inliers wins. The final transform is then refined with least-squares over
    /// those inliers to recover rotation and scale in addition to translation.
    ///
    /// This approach is robust to the false-match consensus that plagues descriptor-
    /// based matching in sparse emission-line fields: a spurious near-zero translation
    /// can only win if it actually maps most reference stars onto target stars, which
    /// a real inter-session offset cannot do.
    ///
    /// Complexity: O(n_ref² × n_tgt) — fine for up to ~150 stars per frame on CPU.
    /// Returns nil when fewer than `minInliers` stars match under the best candidate.
    static func starMatchingRANSAC(
        refStars: [StarPoint],
        tgtStars: [StarPoint],
        inlierThreshold: Double,
        maxScaleDeviation: Double,
        minInliers: Int
    ) -> (pairs: [(ref: StarPoint, tgt: StarPoint)], transform: SimilarityTransform)? {
        guard refStars.count >= 2, tgtStars.count >= 2 else { return nil }

        let thr2 = inlierThreshold * inlierThreshold
        var bestPairs: [(ref: StarPoint, tgt: StarPoint)] = []

        // Phase 1 — translation search: try every (ri → tj) as a pure translation hypothesis.
        for ri in refStars {
            for tj in tgtStars {
                let tx = tj.x - ri.x, ty = tj.y - ri.y
                var pairs: [(ref: StarPoint, tgt: StarPoint)] = []
                for rk in refStars {
                    let px = rk.x + tx, py = rk.y + ty
                    var bestD2 = thr2, bestTgt: StarPoint? = nil
                    for tk in tgtStars {
                        let dx = tk.x - px, dy = tk.y - py
                        let d2 = dx*dx + dy*dy
                        if d2 < bestD2 { bestD2 = d2; bestTgt = tk }
                    }
                    if let match = bestTgt { pairs.append((rk, match)) }
                }
                if pairs.count > bestPairs.count { bestPairs = pairs }
            }
        }

        guard bestPairs.count >= minInliers else { return nil }

        // Phase 2 — refinement: fit full similarity transform on translation inliers,
        // then re-collect inliers under the refined transform.
        let (coarse, _) = leastSquaresSimilarity(pairs: bestPairs)
        guard abs(coarse.scale - 1.0) <= maxScaleDeviation else { return nil }

        var refinedPairs: [(ref: StarPoint, tgt: StarPoint)] = []
        for ref in refStars {
            let px = coarse.a * ref.x - coarse.b * ref.y + coarse.tx
            let py = coarse.b * ref.x + coarse.a * ref.y + coarse.ty
            var bestD2 = thr2, bestTgt: StarPoint? = nil
            for tgt in tgtStars {
                let dx = tgt.x - px, dy = tgt.y - py
                let d2 = dx*dx + dy*dy
                if d2 < bestD2 { bestD2 = d2; bestTgt = tgt }
            }
            if let match = bestTgt { refinedPairs.append((ref, match)) }
        }

        guard refinedPairs.count >= minInliers else { return nil }

        let (refined, _) = leastSquaresSimilarity(pairs: refinedPairs)
        guard abs(refined.scale - 1.0) <= maxScaleDeviation else { return nil }

        return (refinedPairs, refined)
    }

    /// Euclidean residual of applying `t` to `ref` and comparing with `tgt`.
    static func residual(_ t: SimilarityTransform, ref: StarPoint, tgt: StarPoint) -> Double {
        let cosA = t.scale * cos(t.rotation), sinA = t.scale * sin(t.rotation)
        let px = cosA*ref.x - sinA*ref.y + t.tx
        let py = sinA*ref.x + cosA*ref.y + t.ty
        return sqrt((px-tgt.x)*(px-tgt.x) + (py-tgt.y)*(py-tgt.y))
    }

    // MARK: - GPU-accelerated descriptor matching

    /// Runs the forward and backward nearest-neighbour passes for 2D float descriptors
    /// on the GPU using the `triangle_match_forward` and `triangle_match_backward` Metal kernels.
    ///
    /// The ratio test and mutual cross-check are left to the caller; this function only
    /// returns the raw index/distance arrays so it can be shared by any 2D descriptor matcher.
    ///
    /// Returns nil if the Metal pipeline cannot be created — caller should fall back to CPU.
    static func metalMatch2D(
        refDesc: [(Float, Float)],
        tgtDesc: [(Float, Float)],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> (fwdBestIdx: [Int32], fwdBestDist: [Float], fwdSecDist: [Float], bwdBestIdx: [Int32])? {
        guard !refDesc.isEmpty, !tgtDesc.isEmpty else { return nil }
        guard let library  = AstrophotoKit.makeShaderLibrary(device: device),
              let fwdFn    = library.makeFunction(name: "triangle_match_forward"),
              let bwdFn    = library.makeFunction(name: "triangle_match_backward"),
              let fwdPipeline = try? device.makeComputePipelineState(function: fwdFn),
              let bwdPipeline = try? device.makeComputePipelineState(function: bwdFn)
        else { return nil }

        let nRef = refDesc.count, nTgt = tgtDesc.count

        // Pack as flat Float32 arrays (each descriptor = 2 × Float32 = 8 bytes)
        var refFlat = refDesc.flatMap { [$0.0, $0.1] }
        var tgtFlat = tgtDesc.flatMap { [$0.0, $0.1] }
        var counts  = SIMD2<UInt32>(UInt32(nRef), UInt32(nTgt))

        guard
            let refBuf     = device.makeBuffer(bytes: &refFlat, length: nRef * 8, options: .storageModeShared),
            let tgtBuf     = device.makeBuffer(bytes: &tgtFlat, length: nTgt * 8, options: .storageModeShared),
            let cntBuf     = device.makeBuffer(bytes: &counts,  length: 8,        options: .storageModeShared),
            let fwdIdxBuf  = device.makeBuffer(length: nTgt * 4, options: .storageModeShared),
            let fwdBestBuf = device.makeBuffer(length: nTgt * 4, options: .storageModeShared),
            let fwdSecBuf  = device.makeBuffer(length: nTgt * 4, options: .storageModeShared),
            let bwdIdxBuf  = device.makeBuffer(length: nRef * 4, options: .storageModeShared),
            let cmdBuf     = commandQueue.makeCommandBuffer()
        else { return nil }

        // Forward pass — one thread per target descriptor
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(fwdPipeline)
            enc.setBuffer(refBuf,     offset: 0, index: 0)
            enc.setBuffer(tgtBuf,     offset: 0, index: 1)
            enc.setBuffer(fwdIdxBuf,  offset: 0, index: 2)
            enc.setBuffer(fwdBestBuf, offset: 0, index: 3)
            enc.setBuffer(fwdSecBuf,  offset: 0, index: 4)
            enc.setBuffer(cntBuf,     offset: 0, index: 5)
            let tgW = min(fwdPipeline.maxTotalThreadsPerThreadgroup, nTgt)
            let gcW = (nTgt + tgW - 1) / tgW
            enc.dispatchThreadgroups(MTLSize(width: gcW, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tgW, height: 1, depth: 1))
            enc.endEncoding()
        }

        // Backward pass — one thread per reference descriptor (reuses same counts buffer)
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(bwdPipeline)
            enc.setBuffer(refBuf,    offset: 0, index: 0)
            enc.setBuffer(tgtBuf,    offset: 0, index: 1)
            enc.setBuffer(bwdIdxBuf, offset: 0, index: 2)
            enc.setBuffer(cntBuf,    offset: 0, index: 3)
            let tgW = min(bwdPipeline.maxTotalThreadsPerThreadgroup, nRef)
            let gcW = (nRef + tgW - 1) / tgW
            enc.dispatchThreadgroups(MTLSize(width: gcW, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tgW, height: 1, depth: 1))
            enc.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let fwdBestIdx  = Array(UnsafeBufferPointer(
            start: fwdIdxBuf.contents().assumingMemoryBound(to: Int32.self), count: nTgt))
        let fwdBestDist = Array(UnsafeBufferPointer(
            start: fwdBestBuf.contents().assumingMemoryBound(to: Float.self), count: nTgt))
        let fwdSecDist  = Array(UnsafeBufferPointer(
            start: fwdSecBuf.contents().assumingMemoryBound(to: Float.self), count: nTgt))
        let bwdBestIdx  = Array(UnsafeBufferPointer(
            start: bwdIdxBuf.contents().assumingMemoryBound(to: Int32.self), count: nRef))

        return (fwdBestIdx, fwdBestDist, fwdSecDist, bwdBestIdx)
    }

    /// GPU-accelerated forward+backward nearest-neighbour pass for 4D float descriptors
    /// (used by the quad-based registration pipeline).
    /// Returns nil on Metal pipeline failure — caller should fall back to CPU.
    static func metalMatch4D(
        refDesc: [(Float, Float, Float, Float)],
        tgtDesc: [(Float, Float, Float, Float)],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> (fwdBestIdx: [Int32], fwdBestDist: [Float], fwdSecDist: [Float], bwdBestIdx: [Int32])? {
        guard !refDesc.isEmpty, !tgtDesc.isEmpty else { return nil }
        guard let library  = AstrophotoKit.makeShaderLibrary(device: device),
              let fwdFn    = library.makeFunction(name: "quad_match_forward"),
              let bwdFn    = library.makeFunction(name: "quad_match_backward"),
              let fwdPipeline = try? device.makeComputePipelineState(function: fwdFn),
              let bwdPipeline = try? device.makeComputePipelineState(function: bwdFn)
        else { return nil }

        let nRef = refDesc.count, nTgt = tgtDesc.count

        // Pack as flat Float32 arrays (each descriptor = 4 × Float32 = 16 bytes)
        var refFlat = refDesc.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        var tgtFlat = tgtDesc.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        var counts  = SIMD2<UInt32>(UInt32(nRef), UInt32(nTgt))

        guard
            let refBuf     = device.makeBuffer(bytes: &refFlat, length: nRef * 16, options: .storageModeShared),
            let tgtBuf     = device.makeBuffer(bytes: &tgtFlat, length: nTgt * 16, options: .storageModeShared),
            let cntBuf     = device.makeBuffer(bytes: &counts,  length: 8,         options: .storageModeShared),
            let fwdIdxBuf  = device.makeBuffer(length: nTgt * 4, options: .storageModeShared),
            let fwdBestBuf = device.makeBuffer(length: nTgt * 4, options: .storageModeShared),
            let fwdSecBuf  = device.makeBuffer(length: nTgt * 4, options: .storageModeShared),
            let bwdIdxBuf  = device.makeBuffer(length: nRef * 4, options: .storageModeShared),
            let cmdBuf     = commandQueue.makeCommandBuffer()
        else { return nil }

        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(fwdPipeline)
            enc.setBuffer(refBuf,     offset: 0, index: 0)
            enc.setBuffer(tgtBuf,     offset: 0, index: 1)
            enc.setBuffer(fwdIdxBuf,  offset: 0, index: 2)
            enc.setBuffer(fwdBestBuf, offset: 0, index: 3)
            enc.setBuffer(fwdSecBuf,  offset: 0, index: 4)
            enc.setBuffer(cntBuf,     offset: 0, index: 5)
            let tgW = min(fwdPipeline.maxTotalThreadsPerThreadgroup, nTgt)
            let gcW = (nTgt + tgW - 1) / tgW
            enc.dispatchThreadgroups(MTLSize(width: gcW, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tgW, height: 1, depth: 1))
            enc.endEncoding()
        }

        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(bwdPipeline)
            enc.setBuffer(refBuf,    offset: 0, index: 0)
            enc.setBuffer(tgtBuf,    offset: 0, index: 1)
            enc.setBuffer(bwdIdxBuf, offset: 0, index: 2)
            enc.setBuffer(cntBuf,    offset: 0, index: 3)
            let tgW = min(bwdPipeline.maxTotalThreadsPerThreadgroup, nRef)
            let gcW = (nRef + tgW - 1) / tgW
            enc.dispatchThreadgroups(MTLSize(width: gcW, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tgW, height: 1, depth: 1))
            enc.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let fwdBestIdx  = Array(UnsafeBufferPointer(
            start: fwdIdxBuf.contents().assumingMemoryBound(to: Int32.self), count: nTgt))
        let fwdBestDist = Array(UnsafeBufferPointer(
            start: fwdBestBuf.contents().assumingMemoryBound(to: Float.self), count: nTgt))
        let fwdSecDist  = Array(UnsafeBufferPointer(
            start: fwdSecBuf.contents().assumingMemoryBound(to: Float.self), count: nTgt))
        let bwdBestIdx  = Array(UnsafeBufferPointer(
            start: bwdIdxBuf.contents().assumingMemoryBound(to: Int32.self), count: nRef))

        return (fwdBestIdx, fwdBestDist, fwdSecDist, bwdBestIdx)
    }

    // MARK: - Statistics

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid    = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid-1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Processor runner helpers

    private static func runFrame(
        _ processor: any Processor,
        inputs: [String: ProcessData],
        outputKey: String,
        params: [String: Parameter] = [:],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Frame {
        var placeholder: [String: ProcessData] = [outputKey: emptyFrame()]
        try processor.execute(inputs: inputs, outputs: &placeholder,
                              parameters: params, device: device, commandQueue: commandQueue)
        guard let f = placeholder[outputKey] as? Frame else {
            throw ProcessorExecutionError.executionFailed("\(processor.id): missing output '\(outputKey)'")
        }
        return f
    }

    static func emptyFrame() -> Frame {
        Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float,
              texture: nil, outputProcess: nil, inputProcesses: [])
    }

    // MARK: - 4×4 Gaussian elimination (partial pivot)

    static func solve4x4(matrix: [[Double]], rhs: [Double]) -> [Double]? {
        var A = matrix, b = rhs
        let n = 4
        for col in 0..<n {
            var maxRow = col
            for row in (col+1)..<n where abs(A[row][col]) > abs(A[maxRow][col]) { maxRow = row }
            A.swapAt(col, maxRow); b.swapAt(col, maxRow)
            guard abs(A[col][col]) > 1e-12 else { return nil }
            for row in (col+1)..<n {
                let f = A[row][col] / A[col][col]
                for j in col..<n { A[row][j] -= f * A[col][j] }
                b[row] -= f * b[col]
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
