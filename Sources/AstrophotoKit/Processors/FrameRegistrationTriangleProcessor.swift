import Foundation
import Metal
import TabularData
import os

// MARK: - Triangle-specific types

/// Normalized 3-star triangle descriptor (scale- and rotation-invariant).
///
/// Given three stars, let c = longest side, b = middle side, a = shortest of the
/// two remaining sides adjacent to the peak vertex (the vertex opposite c).
///
/// Descriptor: (a/c, b/c) — two values in (0, 1] that are invariant under similarity
/// transforms. The vertex ordering (s1 = peak, s2 adjacent to shorter leg, s3 adjacent
/// to longer leg) allows unambiguous vertex alignment across matched triangle pairs.
private struct TriangleDescriptor {
    let ratio1: Double  // shorter leg / longest side (≤ ratio2)
    let ratio2: Double  // longer leg  / longest side
    let s1: StarPoint   // peak vertex (opposite longest side)
    let s2: StarPoint   // endpoint of longest side adjacent to shorter leg
    let s3: StarPoint   // endpoint of longest side adjacent to longer leg
}

private struct RegistrationRow {
    let frameIndex:    Int
    let transform:     SimilarityTransform
    let matchCount:    Int
    let rawMatchCount: Int
    let rmse:          Double
    let stats:         FrameStats
    let success:       Bool
}

// MARK: - Processor

/// Registers multiple astronomical frames relative to a common reference frame using
/// 3-star triangle pattern matching.
///
/// Triangle patterns yield C(n,3) patterns from n stars vs C(n,4) for 4-star quads,
/// giving substantially more pattern coverage when the star count is low (n ≤ 8).
/// This makes triangle registration the preferred choice for very sparse star fields.
///
/// The algorithm mirrors `FrameRegistrationProcessor` step-for-step:
/// 1. Shared star-detection sub-pipeline (grayscale → blur → background subtraction →
///    threshold → erosion → dilation → connected components → FWHM).
/// 2. Extended-source filter (`max_fwhm_ratio`).
/// 3. kNN-based triangle formation: for each star, triangles are formed with pairs of
///    its `k_neighbors` nearest neighbours; duplicate triangles are suppressed.
/// 4. Descriptor matching: Lowe's ratio test + mutual cross-check.
/// 5. Scale-constrained RANSAC + least-squares similarity transform.
/// 6. Success-rate gate with informative error on failure.
///
/// **Output schema is identical to `FrameRegistrationProcessor`** — both pipelines
/// produce the same `registration_table` columns and the optional `reference_stars` table.
public struct FrameRegistrationTriangleProcessor: Processor {
    public var id: String { "frame_registration_triangle" }
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
        let matchThreshold      = parameters["match_threshold"]?.doubleValue  ?? 0.05
        let minMatches          = parameters["min_matches"]?.intValue         ?? 4
        let ransacIterations    = parameters["ransac_iterations"]?.intValue   ?? 100
        let inlierThreshold     = parameters["inlier_threshold"]?.doubleValue ?? 3.0
        let blurRadius          = parameters["blur_radius"]?.doubleValue      ?? 3.0
        let thresholdValue      = parameters["threshold_value"]?.doubleValue  ?? 3.0
        let erosionKernel       = parameters["erosion_kernel_size"]?.intValue ?? 3
        let dilationKernel      = parameters["dilation_kernel_size"]?.intValue ?? 3
        let maxStars            = parameters["max_stars"]?.intValue           ?? 100
        let minDistancePct      = parameters["min_distance_percent"]?.doubleValue ?? 1.0
        let kNeighbors          = parameters["k_neighbors"]?.intValue         ?? 8
        let maxScaleDeviation   = parameters["max_scale_deviation"]?.doubleValue  ?? 0.05
        let ratioThreshold      = parameters["ratio_threshold"]?.doubleValue  ?? 0.8
        let minSuccessRate      = parameters["min_success_rate"]?.doubleValue ?? 0.75
        let maxFWHMRatio        = parameters["max_fwhm_ratio"]?.doubleValue   ?? 2.5
        let maxEccentricity     = parameters["max_eccentricity"]?.doubleValue ?? 0.0

        // ── Star detection ───────────────────────────────────────────────────────
        var perFrame: [(triangles: [TriangleDescriptor], stars: [StarPoint], stats: FrameStats)] = []
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
            let diag    = sqrt(imageWidth * imageWidth + imageHeight * imageHeight)
            let minDist = diag * minDistancePct / 100.0
            let minArea = minDist * minDist * 0.01
            let triangles = buildTriangles(from: stars, kNeighbors: kNeighbors, minArea: minArea)
            let stats = RegistrationCore.extractStats(from: starsTable,
                                                      skyBackground: skyBg, skyNoise: skyNoise)
            Logger.processor.info("FrameRegistrationTriangle: \(stars.count) stars, \(triangles.count) triangles")
            perFrame.append((triangles: triangles, stars: stars, stats: stats))
        }

        // ── Reference frame ──────────────────────────────────────────────────────
        let refIdx: Int
        if referenceFrameParam >= 0 && referenceFrameParam < perFrame.count {
            refIdx = referenceFrameParam
        } else {
            refIdx = RegistrationCore.chooseBestFrame(perFrame.map { $0.stats })
        }
        Logger.processor.info("FrameRegistrationTriangle: reference frame = \(refIdx)")

        try RegistrationCore.checkEquipmentConsistency(frames: frameSet.frames, referenceIndex: refIdx)

        // ── Per-frame registration ───────────────────────────────────────────────
        var rows: [RegistrationRow] = []
        let refTriangles = perFrame[refIdx].triangles
        let refStars     = perFrame[refIdx].stars

        for (i, frameData) in perFrame.enumerated() {
            if i == refIdx {
                rows.append(RegistrationRow(frameIndex: i, transform: .identity,
                                            matchCount: frameData.triangles.count, rawMatchCount: frameData.stars.count,
                                            rmse: 0, stats: frameData.stats, success: true))
                continue
            }
            let rawMatchCount = RegistrationCore.countRawMatches(
                refStars: refStars, tgtStars: frameData.stars, threshold: inlierThreshold)
            Logger.processor.info("FrameRegistrationTriangle: frame \(i) — raw overlap (no transform): \(rawMatchCount)/\(refStars.count) ref stars within \(inlierThreshold, format: .fixed(precision: 1)) px of a target star")
            let (transform, matchCount, rmse, success) = computeTransform(
                reference: refTriangles, target: frameData.triangles,
                matchThreshold: matchThreshold, minMatches: minMatches,
                ransacIterations: ransacIterations, inlierThreshold: inlierThreshold,
                maxScaleDeviation: maxScaleDeviation, ratioThreshold: ratioThreshold,
                device: device, commandQueue: commandQueue
            )
            rows.append(RegistrationRow(frameIndex: i, transform: transform,
                                        matchCount: matchCount, rawMatchCount: rawMatchCount,
                                        rmse: rmse, stats: frameData.stats, success: success))
        }

        // ── Success-rate gate ────────────────────────────────────────────────────
        let successCount = rows.filter { $0.success }.count
        let successRate  = Double(successCount) / Double(rows.count)
        if successRate < minSuccessRate {
            let failed           = rows.filter { !$0.success }
            let tooFewMatchCount = failed.filter { $0.matchCount < minMatches }.count
            let badScaleCount    = failed.filter { $0.matchCount >= minMatches }.count
            throw ProcessorExecutionError.executionFailed(
                RegistrationCore.buildTriangleFailureMessage(
                    successCount: successCount, total: rows.count,
                    successRate: successRate, minSuccessRate: minSuccessRate,
                    tooFewMatchesCount: tooFewMatchCount, badScaleCount: badScaleCount
                )
            )
        }

        // ── Output DataFrame ─────────────────────────────────────────────────────
        let sortedRows = rows.sorted { $0.frameIndex < $1.frameIndex }
        outputs["registration_table"] = buildOutputTable(
            sortedRows: sortedRows, frameSet: frameSet, outputs: &outputs
        )

        if var refStarsTable = outputs["reference_stars"] as? TableData {
            let refStars = perFrame[refIdx].stars
            var refDF = DataFrame()
            refDF.append(column: Column<Int>   (name: "star_index", contents: refStars.indices.map { $0 }))
            refDF.append(column: Column<Double>(name: "x",          contents: refStars.map { $0.x }))
            refDF.append(column: Column<Double>(name: "y",          contents: refStars.map { $0.y }))
            refStarsTable.dataFrame = refDF
            outputs["reference_stars"] = refStarsTable
        }
    }

    // MARK: - Star extraction

    /// Selects up to `maxStars` brightest stars with a minimum mutual distance filter.
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

    // MARK: - Triangle formation

    /// Builds triangle descriptors using a kNN graph.
    /// For each star, triangles are formed with every pair of its k nearest neighbours.
    /// Duplicate triangles (same three star indices in any order) are suppressed.
    private func buildTriangles(
        from stars: [StarPoint],
        kNeighbors: Int,
        minArea: Double
    ) -> [TriangleDescriptor] {
        guard stars.count >= 3 else { return [] }
        let k = min(kNeighbors, stars.count - 1)
        var seen   = Set<[Int]>()
        var result = [TriangleDescriptor]()

        for i in 0..<stars.count {
            let nbrs = kNearestIndices(of: i, in: stars, k: k)
            for j in 0..<nbrs.count {
                for l in (j+1)..<nbrs.count {
                    let key = [i, nbrs[j], nbrs[l]].sorted()
                    guard seen.insert(key).inserted else { continue }
                    if let tri = makeTriangle(stars[i], stars[nbrs[j]], stars[nbrs[l]],
                                             minArea: minArea) {
                        result.append(tri)
                    }
                }
            }
        }
        return result
    }

    private func kNearestIndices(of i: Int, in stars: [StarPoint], k: Int) -> [Int] {
        var dists: [(d2: Double, idx: Int)] = []
        let si = stars[i]
        for j in 0..<stars.count where j != i {
            let dx = stars[j].x - si.x, dy = stars[j].y - si.y
            dists.append((dx*dx + dy*dy, j))
        }
        dists.sort { $0.d2 < $1.d2 }
        return dists.prefix(k).map { $0.idx }
    }

    /// Constructs a `TriangleDescriptor` from three stars, or returns nil for degenerate triangles.
    private func makeTriangle(
        _ a: StarPoint, _ b: StarPoint, _ c: StarPoint,
        minArea: Double
    ) -> TriangleDescriptor? {
        let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2.0
        guard area >= minArea else { return nil }

        let dAB = hypot(b.x - a.x, b.y - a.y)
        let dAC = hypot(c.x - a.x, c.y - a.y)
        let dBC = hypot(c.x - b.x, c.y - b.y)

        // Identify longest side and its opposite (peak) vertex
        let longest: Double
        let s1: StarPoint       // peak
        var s2: StarPoint       // one end of longest side
        var s3: StarPoint       // other end of longest side
        var legA: Double        // dist(s1, s2)
        var legB: Double        // dist(s1, s3)

        if dAB >= dAC && dAB >= dBC {
            longest = dAB; s1 = c; s2 = a; s3 = b; legA = dAC; legB = dBC
        } else if dAC >= dAB && dAC >= dBC {
            longest = dAC; s1 = b; s2 = a; s3 = c; legA = dAB; legB = dBC
        } else {
            longest = dBC; s1 = a; s2 = b; s3 = c; legA = dAB; legB = dAC
        }
        guard longest > 0 else { return nil }

        // Canonical ordering: leg to s2 ≤ leg to s3
        if legA > legB {
            swap(&s2, &s3)
            swap(&legA, &legB)
        }

        return TriangleDescriptor(ratio1: legA / longest, ratio2: legB / longest,
                                  s1: s1, s2: s2, s3: s3)
    }

    // MARK: - Transform computation

    private func computeTransform(
        reference:         [TriangleDescriptor],
        target:            [TriangleDescriptor],
        matchThreshold:    Double,
        minMatches:        Int,
        ransacIterations:  Int,
        inlierThreshold:   Double,
        maxScaleDeviation: Double,
        ratioThreshold:    Double,
        device:            MTLDevice,
        commandQueue:      MTLCommandQueue
    ) -> (transform: SimilarityTransform, matchCount: Int, rmse: Double, success: Bool) {
        let matches = matchTriangles(reference: reference, target: target,
                                     threshold: matchThreshold, ratioThreshold: ratioThreshold,
                                     device: device, commandQueue: commandQueue)
        guard matches.count >= minMatches else {
            Logger.processor.warning("FrameRegistrationTriangle: only \(matches.count) triangle matches (need \(minMatches)) — using identity")
            return (.identity, matches.count, 0, false)
        }

        var pairs: [(ref: StarPoint, tgt: StarPoint)] = []
        for (refT, tgtT) in matches {
            pairs.append((ref: refT.s1, tgt: tgtT.s1))
            pairs.append((ref: refT.s2, tgt: tgtT.s2))
            pairs.append((ref: refT.s3, tgt: tgtT.s3))
        }

        let (bestInliers, _) = RegistrationCore.ransac(
            pairs: pairs, iterations: ransacIterations,
            inlierThreshold: inlierThreshold, maxScaleDeviation: maxScaleDeviation
        )
        let (transform, rmse) = RegistrationCore.leastSquaresSimilarity(
            pairs: bestInliers.count >= 4 ? bestInliers : pairs
        )

        guard abs(transform.scale - 1.0) <= maxScaleDeviation else {
            Logger.processor.warning("FrameRegistrationTriangle: frame rejected — scale \(transform.scale, format: .fixed(precision: 4)) deviates from 1.0 by more than \(maxScaleDeviation)")
            return (.identity, matches.count, rmse, false)
        }
        return (transform, matches.count, rmse, true)
    }

    // MARK: - Triangle matching (ratio test + mutual cross-check)

    /// Matches triangle descriptors using the GPU when available, falling back to CPU.
    ///
    /// GPU path: dispatches `triangle_match_forward` and `triangle_match_backward` Metal
    /// kernels to compute the full pairwise distance matrix in parallel, then applies the
    /// ratio test and mutual cross-check on CPU from the small result arrays.
    ///
    /// CPU path: identical O(|ref| × |tgt|) scan, used when Metal pipeline creation fails.
    private func matchTriangles(
        reference:      [TriangleDescriptor],
        target:         [TriangleDescriptor],
        threshold:      Double,
        ratioThreshold: Double,
        device:         MTLDevice,
        commandQueue:   MTLCommandQueue
    ) -> [(TriangleDescriptor, TriangleDescriptor)] {
        guard !reference.isEmpty, !target.isEmpty else { return [] }

        let fwdBestIdx:  [Int32]
        let fwdBestDist: [Float]
        let fwdSecDist:  [Float]
        let bwdBestIdx:  [Int32]

        let refDesc = reference.map { (Float($0.ratio1), Float($0.ratio2)) }
        let tgtDesc = target.map    { (Float($0.ratio1), Float($0.ratio2)) }

        if let gpu = RegistrationCore.metalMatch2D(refDesc: refDesc, tgtDesc: tgtDesc,
                                                   device: device, commandQueue: commandQueue) {
            (fwdBestIdx, fwdBestDist, fwdSecDist, bwdBestIdx) = gpu
        } else {
            // CPU fallback
            var fi  = [Int32](repeating: -1,   count: target.count)
            var fd  = [Float](repeating: .infinity, count: target.count)
            var sd  = [Float](repeating: .infinity, count: target.count)
            var bi  = [Int32](repeating: -1,   count: reference.count)
            var bd  = [Float](repeating: .infinity, count: reference.count)
            for (ti, tq) in tgtDesc.enumerated() {
                for (ri, rq) in refDesc.enumerated() {
                    let d1 = tq.0 - rq.0, d2 = tq.1 - rq.1
                    let d  = (d1*d1 + d2*d2).squareRoot()
                    if d < fd[ti] { sd[ti] = fd[ti]; fd[ti] = d; fi[ti] = Int32(ri) }
                    else if d < sd[ti] { sd[ti] = d }
                    if d < bd[ri] { bd[ri] = d; bi[ri] = Int32(ti) }
                }
            }
            fwdBestIdx = fi; fwdBestDist = fd; fwdSecDist = sd; bwdBestIdx = bi
        }

        // Ratio test + mutual cross-check (CPU, tiny arrays)
        let thresh = Float(threshold), ratio = Float(ratioThreshold)
        var matches: [(TriangleDescriptor, TriangleDescriptor)] = []
        for (ti, tq) in target.enumerated() {
            let ri = Int(fwdBestIdx[ti])
            guard ri >= 0, fwdBestDist[ti] < thresh else { continue }
            if fwdSecDist[ti] < .infinity && fwdBestDist[ti] / fwdSecDist[ti] >= ratio { continue }
            guard bwdBestIdx[ri] == Int32(ti) else { continue }
            matches.append((reference[ri], tq))
        }
        return matches
    }

    // MARK: - Output table (same schema as FrameRegistrationProcessor)

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
        df.append(column: Column(name: "raw_match_count",
            contents: sortedRows.map { Int32($0.rawMatchCount) }))
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
