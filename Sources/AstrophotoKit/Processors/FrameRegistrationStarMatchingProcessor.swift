import Foundation
import Metal
import TabularData
import os

/// Registers multiple astronomical frames using direct star-position matching.
///
/// Instead of building geometric patterns (quads or triangles) from detected stars and
/// matching their descriptors, this processor tries every possible reference→target star
/// correspondence as a translation hypothesis, counts how many other stars agree with that
/// translation, and takes the consensus winner. The winning translation is then refined
/// with least-squares to recover the full similarity transform (translation + rotation +
/// scale).
///
/// This approach is immune to the false-match consensus that affects descriptor-based
/// methods in sparse emission-line fields: a spurious near-zero translation only wins if
/// it literally maps most reference stars onto target stars, which an uncorrected
/// inter-session offset cannot do.
///
/// **When to use:**
/// Use this processor when `frame_registration` (quad) and `frame_registration_triangle`
/// both produce doubled/shifted stars because their descriptor matching converges on a
/// wrong transform. It is O(n³) in the number of stars per frame, which is fast for
/// sparse fields (< ~150 stars). For dense fields, prefer the quad pipeline which is
/// more selective at the matching stage.
///
/// **Output schema** is identical to `FrameRegistrationProcessor` — the same
/// `registration_table` columns and optional `reference_stars` table.
public struct FrameRegistrationStarMatchingProcessor: Processor {
    public var id: String { "frame_registration_star_matching" }
    public init() {}

    public func execute(
        inputs:       [String: ProcessData],
        outputs:      inout [String: ProcessData],
        parameters:   [String: Parameter],
        device:       MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let frameSet = inputs["input_frames"] as? FrameSet else {
            throw ProcessorExecutionError.missingRequiredInput("input_frames")
        }
        guard !frameSet.frames.isEmpty else {
            throw ProcessorExecutionError.executionFailed("input_frames FrameSet is empty")
        }

        // ── Parameters ──────────────────────────────────────────────────────────
        let referenceFrameParam = parameters["reference_frame"]?.intValue     ?? -1
        let minMatches          = parameters["min_matches"]?.intValue         ?? 4
        let inlierThreshold     = parameters["inlier_threshold"]?.doubleValue ?? 3.0
        let blurRadius          = parameters["blur_radius"]?.doubleValue      ?? 3.0
        let thresholdValue      = parameters["threshold_value"]?.doubleValue  ?? 3.0
        let erosionKernel       = parameters["erosion_kernel_size"]?.intValue ?? 3
        let dilationKernel      = parameters["dilation_kernel_size"]?.intValue ?? 3
        let maxStars            = parameters["max_stars"]?.intValue           ?? 100
        let minDistancePct      = parameters["min_distance_percent"]?.doubleValue ?? 1.0
        let maxScaleDeviation   = parameters["max_scale_deviation"]?.doubleValue  ?? 0.05
        let minSuccessRate      = parameters["min_success_rate"]?.doubleValue ?? 0.75
        let maxFWHMRatio        = parameters["max_fwhm_ratio"]?.doubleValue   ?? 2.5
        let maxEccentricity     = parameters["max_eccentricity"]?.doubleValue ?? 0.0

        // ── Star detection ───────────────────────────────────────────────────────
        var perFrame: [(stars: [StarPoint], stats: FrameStats)] = []
        for frame in frameSet.frames {
            let (starsTable, skyBg, skyNoise) = try RegistrationCore.detectStars(
                frame: frame, device: device, commandQueue: commandQueue,
                blurRadius: blurRadius, thresholdValue: thresholdValue,
                erosionKernel: erosionKernel, dilationKernel: dilationKernel,
                maxFWHMRatio: maxFWHMRatio, maxEccentricity: maxEccentricity
            )
            let imageWidth  = Double(frame.texture?.width  ?? 1)
            let imageHeight = Double(frame.texture?.height ?? 1)
            let stars = extractStars(from: starsTable, maxStars: maxStars,
                                     minDistancePct: minDistancePct,
                                     imageWidth: imageWidth, imageHeight: imageHeight)
            let stats = RegistrationCore.extractStats(from: starsTable,
                                                      skyBackground: skyBg, skyNoise: skyNoise)
            Logger.processor.info("FrameRegistrationStarMatching: \(stars.count) stars detected")
            perFrame.append((stars: stars, stats: stats))
        }

        // ── Reference frame ──────────────────────────────────────────────────────
        let refIdx: Int
        if referenceFrameParam >= 0 && referenceFrameParam < perFrame.count {
            refIdx = referenceFrameParam
        } else {
            refIdx = RegistrationCore.chooseBestFrame(perFrame.map { $0.stats })
        }
        Logger.processor.info("FrameRegistrationStarMatching: reference frame = \(refIdx)")

        try RegistrationCore.checkEquipmentConsistency(frames: frameSet.frames, referenceIndex: refIdx)

        // ── Per-frame registration ───────────────────────────────────────────────
        let refStars = perFrame[refIdx].stars
        var rows: [RegistrationRow] = []

        for (i, frameData) in perFrame.enumerated() {
            if i == refIdx {
                rows.append(RegistrationRow(frameIndex: i, transform: .identity,
                                            matchCount: refStars.count, rmse: 0,
                                            stats: frameData.stats, success: true))
                continue
            }

            guard let result = RegistrationCore.starMatchingRANSAC(
                refStars: refStars, tgtStars: frameData.stars,
                inlierThreshold: inlierThreshold,
                maxScaleDeviation: maxScaleDeviation,
                minInliers: minMatches
            ) else {
                Logger.processor.warning("FrameRegistrationStarMatching: frame \(i) — fewer than \(minMatches) stars matched, using identity")
                rows.append(RegistrationRow(frameIndex: i, transform: .identity,
                                            matchCount: 0, rmse: 0,
                                            stats: frameData.stats, success: false))
                continue
            }

            let (_, rmse) = RegistrationCore.leastSquaresSimilarity(pairs: result.pairs)
            Logger.processor.info("FrameRegistrationStarMatching: frame \(i) — \(result.pairs.count) matched stars, rmse \(rmse, format: .fixed(precision: 2)) px")
            rows.append(RegistrationRow(frameIndex: i, transform: result.transform,
                                        matchCount: result.pairs.count, rmse: rmse,
                                        stats: frameData.stats, success: true))
        }

        // ── Success-rate gate ────────────────────────────────────────────────────
        let successCount = rows.filter { $0.success }.count
        let successRate  = Double(successCount) / Double(rows.count)
        if successRate < minSuccessRate {
            let failed = rows.filter { !$0.success }
            throw ProcessorExecutionError.executionFailed(
                RegistrationCore.buildStarMatchingFailureMessage(
                    successCount: successCount, total: rows.count,
                    successRate: successRate, minSuccessRate: minSuccessRate,
                    failedCount: failed.count
                )
            )
        }

        // ── Output DataFrame ─────────────────────────────────────────────────────
        let sortedRows = rows.sorted { $0.frameIndex < $1.frameIndex }
        outputs["registration_table"] = buildOutputTable(
            sortedRows: sortedRows, frameSet: frameSet, outputs: &outputs
        )

        if var refStarsTable = outputs["reference_stars"] as? TableData {
            var refDF = DataFrame()
            refDF.append(column: Column<Int>   (name: "star_index", contents: refStars.indices.map { $0 }))
            refDF.append(column: Column<Double>(name: "x",          contents: refStars.map { $0.x }))
            refDF.append(column: Column<Double>(name: "y",          contents: refStars.map { $0.y }))
            refStarsTable.dataFrame = refDF
            outputs["reference_stars"] = refStarsTable
        }
    }

    // MARK: - Star extraction (same as triangle processor)

    private func extractStars(
        from table: TableData,
        maxStars: Int,
        minDistancePct: Double,
        imageWidth: Double,
        imageHeight: Double
    ) -> [StarPoint] {
        guard let df = table.dataFrame, !df.rows.isEmpty else { return [] }

        var candidates: [(x: Double, y: Double, flux: Double)] = []
        for row in df.rows {
            guard let x = row["centroid_x"] as? Double,
                  let y = row["centroid_y"] as? Double else { continue }
            candidates.append((x, y, (row["flux"] as? Double) ?? 0))
        }
        candidates.sort { $0.flux > $1.flux }

        let diag     = sqrt(imageWidth * imageWidth + imageHeight * imageHeight)
        let minDist  = diag * minDistancePct / 100.0
        let minDist2 = minDist * minDist

        var result: [StarPoint] = []
        for c in candidates {
            let tooClose = result.contains { s in
                let dx = s.x - c.x, dy = s.y - c.y
                return dx*dx + dy*dy < minDist2
            }
            if !tooClose {
                result.append(StarPoint(x: c.x, y: c.y))
                if result.count >= maxStars { break }
            }
        }
        return result
    }

    // MARK: - Output table (same schema as the other registration processors)

    private func buildOutputTable(
        sortedRows: [RegistrationRow],
        frameSet: FrameSet,
        outputs: inout [String: ProcessData]
    ) -> TableData {
        let iso8601Formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

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
            return TableData()
        }
        regTable.dataFrame = df
        return regTable
    }
}

// MARK: - Private types (mirrors FrameRegistrationTriangleProcessor)

private struct RegistrationRow {
    let frameIndex: Int
    let transform:  SimilarityTransform
    let matchCount: Int
    let rmse:       Double
    let stats:      FrameStats
    let success:    Bool
}
