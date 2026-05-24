import Foundation
import Metal
import TabularData
import os

/// Processor that detects donut-shaped out-of-focus star images in a reflector telescope
/// image using radial profile analysis. This is a CPU-only alternative to `HoughCircleProcessor`.
///
/// For each CC blob centroid the processor:
///   1. Computes the mean pixel intensity at every integer radius r from 0 to `r_max`.
///   2. Locates the **outer ring** as the peak of the radial profile.
///   3. Locates the **inner shadow** as the profile minimum between r=0 and the peak.
///   4. Refines the **inner shadow centre** via an intensity-weighted centroid of the
///      dark pixels within the shadow region — this gives the collimation offset vector.
///
/// The output `donuts` table has the same schema as `HoughCircleProcessor` so all
/// downstream steps (`collimation_analysis`, `hough_circle_overlay`) work unchanged.
///
/// **Inputs**
/// - `input_frame`    (Frame)     — grayscale r32Float source image
/// - `star_positions` (TableData) — blob centroids from `connected_components`
///
/// **Parameters**
/// - `r_min`                 Int    (default  20) — minimum outer ring radius (pixels)
/// - `r_max`                 Int    (default 150) — maximum outer ring radius (pixels)
/// - `min_peak_ratio`        Double (default 2.0) — minimum ratio of ring peak to background
/// - `margin`                Int    (default  20) — extra pixels beyond r_max for boundary check
/// - `inner_center_search_r` Double (default 0.5) — inner center search radius as fraction of inner_r
///
/// **Outputs**
/// - `donuts` (TableData) — same 14-column schema as `HoughCircleProcessor`
public struct RadialProfileProcessor: Processor {

    public var id: String { "radial_profile" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        let rMin                = parameters["r_min"]?.intValue                   ?? 20
        let rMax                = parameters["r_max"]?.intValue                   ?? 150
        let minPeakRatio        = parameters["min_peak_ratio"]?.doubleValue       ?? 1.5
        let margin              = parameters["margin"]?.intValue                  ?? 20
        let innerCenterSearchR  = parameters["inner_center_search_r"]?.doubleValue ?? 0.5

        guard rMin > 0, rMax >= rMin else {
            throw ProcessorExecutionError.executionFailed("r_min must be > 0 and r_max >= r_min")
        }

        let logMsg = "RadialProfileProcessor: r_min=\(rMin) r_max=\(rMax) image \(inputTexture.width)×\(inputTexture.height)"
        Logger.processor.debug("\(logMsg)")

        // MARK: - Texture Read

        let W = inputTexture.width
        let H = inputTexture.height
        var pixels = [Float](repeating: 0, count: W * H)
        inputTexture.getBytes(
            &pixels,
            bytesPerRow: W * MemoryLayout<Float>.stride,
            from: MTLRegionMake2D(0, 0, W, H),
            mipmapLevel: 0
        )

        // MARK: - Candidate Extraction

        guard let posTable = inputs["star_positions"] as? TableData,
              let df = posTable.dataFrame else {
            Logger.processor.warning("RadialProfileProcessor: no star_positions input — writing empty donuts table")
            try writeDonutsTable(outputs: &outputs, donuts: [])
            return
        }

        let candidates = extractCandidates(from: df, rMin: rMin, rMax: rMax, margin: margin,
                                           imageWidth: W, imageHeight: H)
        Logger.processor.debug("RadialProfileProcessor: \(candidates.count)/\(df.rows.count) blobs passed area/boundary filter")

        // MARK: - Per-Candidate Analysis

        var donuts: [DonutRecord] = []

        for candidate in candidates {
            let cx = Double(candidate.x)
            let cy = Double(candidate.y)

            let profile = computeRadialProfile(pixels: pixels, W: W, H: H,
                                               cx: cx, cy: cy, rMax: rMax)

            // Initial ring detection from CC centroid (may be inaccurate if blob is irregular)
            guard let roughRing = detectRing(profile: profile, rMin: rMin, rMax: rMax,
                                             minPeakRatio: minPeakRatio) else {
                // Log why this candidate was rejected (profile from uncorrected CC centroid)
                var peakIdx = rMin, peakVal = profile[rMin]
                for r in (rMin+1)...rMax { if profile[r] > peakVal { peakVal = profile[r]; peakIdx = r } }
                let tailStart = min(peakIdx + peakIdx / 2, rMax)
                var background = profile[tailStart]
                for r in tailStart...rMax { if profile[r] < background { background = profile[r] } }
                background = max(background, 1e-9)
                var valIdx = 0, valVal = profile[0]
                for r in 1..<peakIdx { if profile[r] < valVal { valVal = profile[r]; valIdx = r } }
                let rejectMsg = String(format: "RadialProfileProcessor: (%d,%d) rejected — peak=%.4f@r=%d bg=%.4f ratio=%.2f valley=%.4f@r=%d p2v=%.2f",
                    candidate.x, candidate.y, peakVal, peakIdx, background,
                    peakVal/background, valVal, valIdx,
                    valVal > 0 ? peakVal/valVal : 999.0)
                Logger.processor.debug("\(rejectMsg)")
                continue
            }

            // Refine outer center: grid-search around the CC centroid computing the full
            // radial profile at each candidate position. The CC centroid of an arc/crescent
            // lands ON the ring, not at its center, so approxR from the initial profile is
            // unreliable. Searching for the position with the highest profile peak avoids
            // any dependence on the (wrong) initial radius estimate.
            let searchStep  = max(3, roughRing.outerR / 6)
            let searchRange = roughRing.outerR   // search up to one full radius from CC centroid
            let (refinedCX, refinedCY, refinedProfile) = refineOuterCenter(
                pixels: pixels, W: W, H: H,
                cx: cx, cy: cy,
                rMin: rMin, rMax: rMax,
                searchRange: searchRange,
                searchStep: searchStep
            )

            guard let ring = detectRing(profile: refinedProfile, rMin: rMin, rMax: rMax,
                                        minPeakRatio: minPeakRatio) else {
                Logger.processor.debug("RadialProfileProcessor: (\(candidate.x),\(candidate.y)) rejected after center refinement")
                continue
            }

            let refineMsg = String(format: "RadialProfileProcessor: refined (%.1f,%.1f)→(%.1f,%.1f) outerR=%d",
                                   cx, cy, refinedCX, refinedCY, ring.outerR)
            Logger.processor.debug("\(refineMsg)")

            let (innerCX, innerCY) = refineInnerCenter(
                pixels: pixels, W: W, H: H,
                outerCX: refinedCX, outerCY: refinedCY,
                profile: refinedProfile,
                outerRIdx: ring.outerR, innerRIdx: ring.innerR,
                innerCenterSearchR: innerCenterSearchR
            )

            donuts.append(DonutRecord(
                outerCX: refinedCX, outerCY: refinedCY, outerR: Double(ring.outerR),
                innerCX: innerCX,   innerCY: innerCY,   innerR: Double(ring.innerR)
            ))
        }

        Logger.processor.info("RadialProfileProcessor: \(donuts.count) donuts detected from \(candidates.count) candidates")
        try writeDonutsTable(outputs: &outputs, donuts: donuts)
    }

    // MARK: - Candidate Extraction

    private struct CandidatePos { let x: Int; let y: Int }

    private func extractCandidates(
        from df: DataFrame,
        rMin: Int, rMax: Int, margin: Int,
        imageWidth W: Int, imageHeight H: Int
    ) -> [CandidatePos] {
        guard let cxCol = df.columns.first(where: { $0.name == "centroid_x" }),
              let cyCol = df.columns.first(where: { $0.name == "centroid_y" }) else { return [] }

        let areaCol = df.columns.first(where: { $0.name == "area" })
        // Require at least a quarter-disc at rMin — large enough to be a real ring arc,
        // small enough to pass even for faint donuts at high threshold.
        let minArea = Double.pi * Double(rMin) * Double(rMin) * 0.25
        let cropHalf = rMax + margin

        var candidates: [CandidatePos] = []
        for i in 0..<df.rows.count {
            if let areaCol = areaCol, let area = areaCol[i] as? Int {
                guard Double(area) >= minArea else { continue }
            }
            guard let cx = cxCol[i] as? Double,
                  let cy = cyCol[i] as? Double else { continue }
            let x = Int(cx.rounded())
            let y = Int(cy.rounded())
            guard x >= cropHalf, y >= cropHalf,
                  x < W - cropHalf, y < H - cropHalf else { continue }
            candidates.append(CandidatePos(x: x, y: y))
        }
        return candidates
    }

    // MARK: - Radial Profile

    /// Computes the mean pixel intensity at each integer radius 0…rMax from (cx, cy).
    private func computeRadialProfile(
        pixels: [Float],
        W: Int, H: Int,
        cx: Double, cy: Double,
        rMax: Int
    ) -> [Double] {
        var sum   = [Double](repeating: 0.0, count: rMax + 1)
        var count = [Int](repeating: 0,      count: rMax + 1)

        let xLo = max(0, Int(cx) - rMax - 1)
        let xHi = min(W - 1, Int(cx) + rMax + 1)
        let yLo = max(0, Int(cy) - rMax - 1)
        let yHi = min(H - 1, Int(cy) + rMax + 1)

        for py in yLo...yHi {
            let dy = Double(py) - cy
            for px in xLo...xHi {
                let dx = Double(px) - cx
                let r = Int((sqrt(dx*dx + dy*dy)).rounded())
                guard r <= rMax else { continue }
                sum[r]   += Double(pixels[py * W + px])
                count[r] += 1
            }
        }

        return (0...rMax).map { r in count[r] > 0 ? sum[r] / Double(count[r]) : 0.0 }
    }

    // MARK: - Ring Detection

    private struct RingMetrics {
        let outerR: Int
        let innerR: Int
        let peakValue: Double
        let valleyValue: Double
    }

    private func detectRing(
        profile: [Double],
        rMin: Int,
        rMax: Int,
        minPeakRatio: Double
    ) -> RingMetrics? {
        guard profile.count > rMax else { return nil }

        // Find peak (outer ring) in [rMin, rMax]
        var peakIdx = rMin
        var peakValue = profile[rMin]
        for r in (rMin + 1)...rMax {
            if profile[r] > peakValue {
                peakValue = profile[r]
                peakIdx = r
            }
        }

        // Background reference: minimum of the profile tail beyond the peak.
        // Using profile[rMax] directly is unreliable because the donut halo can extend
        // to rMax, inflating the background and deflating the ratio.
        let tailStart = min(peakIdx + peakIdx / 2, rMax)  // start at 1.5 × peak radius
        var background = profile[tailStart]
        for r in tailStart...rMax { if profile[r] < background { background = profile[r] } }
        background = max(background, 1e-9)
        guard peakValue / background >= minPeakRatio else { return nil }

        // Find minimum (inner shadow) in [0, peakIdx)
        var innerIdx = 0
        var valleyValue = profile[0]
        for r in 1..<peakIdx {
            if profile[r] < valleyValue {
                valleyValue = profile[r]
                innerIdx = r
            }
        }

        // Require at least a modest peak-to-valley contrast
        let peakToValley = valleyValue > 0 ? peakValue / valleyValue : Double.infinity
        guard peakToValley >= 1.5 else { return nil }

        return RingMetrics(outerR: peakIdx, innerR: innerIdx,
                           peakValue: peakValue, valleyValue: valleyValue)
    }

    // MARK: - Outer Center Refinement

    /// Grid-searches around the CC centroid computing the full radial profile at each
    /// candidate position. Returns the position + profile that yields the highest peak,
    /// which is the best estimate of the true ring center and radius.
    ///
    /// This avoids any dependence on the initial `approxR` from the CC centroid profile,
    /// which is unreliable when the centroid lands on a ring arc rather than near the center.
    private func refineOuterCenter(
        pixels: [Float],
        W: Int, H: Int,
        cx: Double, cy: Double,
        rMin: Int, rMax: Int,
        searchRange: Int,
        searchStep: Int
    ) -> (cx: Double, cy: Double, profile: [Double]) {
        var bestCX = cx, bestCY = cy
        var bestPeak = -Double.infinity
        var bestProfile = [Double](repeating: 0, count: rMax + 1)

        let xLo = Int(cx) - searchRange
        let xHi = Int(cx) + searchRange
        let yLo = Int(cy) - searchRange
        let yHi = Int(cy) + searchRange

        var testX = xLo
        while testX <= xHi {
            var testY = yLo
            while testY <= yHi {
                guard testX >= 0, testX < W, testY >= 0, testY < H else { testY += searchStep; continue }
                let tcx = Double(testX), tcy = Double(testY)

                let profile = computeRadialProfile(pixels: pixels, W: W, H: H,
                                                   cx: tcx, cy: tcy, rMax: rMax)

                // Score = peakValue × peakRadius — strongly prefers large rings over bright
                // small-radius features (inner shadow edge). A ring at r=108 with value 0.10
                // scores 10.8 vs a shadow edge at r=38 with value 0.25 scoring 9.5.
                var peakVal = -Double.infinity
                var peakIdx = rMin
                for r in rMin...rMax {
                    if profile[r] > peakVal { peakVal = profile[r]; peakIdx = r }
                }
                let score = peakVal * Double(peakIdx)

                if score > bestPeak {
                    bestPeak = score
                    bestCX = tcx; bestCY = tcy
                    bestProfile = profile
                }
                testY += searchStep
            }
            testX += searchStep
        }

        return (bestCX, bestCY, bestProfile)
    }

    // MARK: - Inner Center Refinement

    /// Refines the inner shadow centre via intensity-weighted centroid of dark pixels.
    private func refineInnerCenter(
        pixels: [Float],
        W: Int, H: Int,
        outerCX: Double, outerCY: Double,
        profile: [Double],
        outerRIdx: Int,
        innerRIdx: Int,
        innerCenterSearchR: Double
    ) -> (cx: Double, cy: Double) {
        let searchRadius = Double(innerRIdx) * (1.0 + innerCenterSearchR)
        let shadowThreshold = profile[0] + 0.3 * (profile[outerRIdx] - profile[0])

        let xLo = max(0, Int(outerCX - searchRadius - 1))
        let xHi = min(W - 1, Int(outerCX + searchRadius + 1))
        let yLo = max(0, Int(outerCY - searchRadius - 1))
        let yHi = min(H - 1, Int(outerCY + searchRadius + 1))

        var sumWX = 0.0, sumWY = 0.0, totalW = 0.0

        for py in yLo...yHi {
            let dy = Double(py) - outerCY
            for px in xLo...xHi {
                let dx = Double(px) - outerCX
                guard sqrt(dx*dx + dy*dy) <= searchRadius else { continue }
                let pixVal = Double(pixels[py * W + px])
                guard pixVal < shadowThreshold else { continue }
                let weight = shadowThreshold - pixVal
                sumWX  += weight * Double(px)
                sumWY  += weight * Double(py)
                totalW += weight
            }
        }

        guard totalW > 0 else { return (outerCX, outerCY) }
        return (sumWX / totalW, sumWY / totalW)
    }

    // MARK: - Output Writing

    private struct DonutRecord {
        let outerCX: Double, outerCY: Double, outerR: Double
        let innerCX: Double, innerCY: Double, innerR: Double
    }

    private func writeDonutsTable(
        outputs: inout [String: ProcessData],
        donuts: [DonutRecord]
    ) throws {
        guard var table = outputs["donuts"] as? TableData else { return }

        let n = donuts.count
        var df = DataFrame()
        df.append(column: Column(name: "id",               contents: Array(0..<n)))
        df.append(column: Column(name: "outer_cx",         contents: donuts.map(\.outerCX)))
        df.append(column: Column(name: "outer_cy",         contents: donuts.map(\.outerCY)))
        df.append(column: Column(name: "outer_r",          contents: donuts.map(\.outerR)))
        df.append(column: Column(name: "outer_votes",      contents: Array(repeating: 0, count: n)))
        df.append(column: Column(name: "inner_cx",         contents: donuts.map(\.innerCX)))
        df.append(column: Column(name: "inner_cy",         contents: donuts.map(\.innerCY)))
        df.append(column: Column(name: "inner_r",          contents: donuts.map(\.innerR)))
        df.append(column: Column(name: "inner_votes",      contents: Array(repeating: 0, count: n)))
        df.append(column: Column(name: "offset_x",         contents: donuts.map { $0.innerCX - $0.outerCX }))
        df.append(column: Column(name: "offset_y",         contents: donuts.map { $0.innerCY - $0.outerCY }))
        df.append(column: Column(name: "offset_magnitude", contents: donuts.map { d in
            let dx = d.innerCX - d.outerCX, dy = d.innerCY - d.outerCY
            return sqrt(dx*dx + dy*dy)
        }))
        df.append(column: Column(name: "offset_angle",     contents: donuts.map { d in
            atan2(d.innerCY - d.outerCY, d.innerCX - d.outerCX)
        }))
        df.append(column: Column(name: "r_ratio",          contents: donuts.map { $0.outerR > 0 ? $0.innerR / $0.outerR : 0.0 }))

        table.dataFrame = df
        outputs["donuts"] = table
    }
}
