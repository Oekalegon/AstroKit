import Foundation
import Metal
import TabularData
import os

/// Two-phase collimation helper: given a *reference donut* (typically the single brightest
/// detection from `HoughCircleProcessor` with `max_donuts=1`), this processor learns the
/// ring geometry (`outer_r`, `r_ratio`) and then performs a **single-scale full-image**
/// Difference-of-Gaussians search to find all donuts — including very faint ones that would
/// be missed by the per-crop Hough approach.
///
/// Because every out-of-focus star in the same image shares the same optical path, all
/// donuts have identical outer radius and inner/outer ratio.  One reliable detection is
/// therefore enough to calibrate the search for the rest.
///
/// **Algorithm**
/// 1. Read `outer_r` and `r_ratio` from `reference_donut` table (row 0).
/// 2. Compute `DoG = blur(outer_r × sigma_inner) − blur(outer_r × sigma_outer)` on the
///    full-resolution image (GPU).  This responds maximally to rings at radius `outer_r`.
/// 3. Find 2-D local maxima above `min_response` (CPU), apply spatial NMS.
/// 4. For each peak refine the inner shadow centre via intensity-weighted centroid of
///    dark pixels, using `inner_r = outer_r × r_ratio` as the search radius.
///
/// **Inputs**
/// - `input_frame`      (Frame)     — greyscale r32Float image.
/// - `reference_donut`  (TableData) — at least 1 row with `outer_r` and `r_ratio` columns.
///
/// **Parameters**
/// - `min_response`          Double (default 0.001) — minimum DoG peak value; decrease for fainter donuts.
/// - `nms_radius`            Int    (default   20)  — spatial NMS radius in pixels.
/// - `max_donuts`            Int    (default   50)  — maximum donuts to return.
/// - `sigma_ratio_inner`     Double (default  0.8)  — inner Gaussian sigma = outer_r × ratio.
/// - `sigma_ratio_outer`     Double (default  1.2)  — outer Gaussian sigma = outer_r × ratio.
/// - `inner_center_search_r` Double (default  0.5)  — inner search radius as fraction of inner_r.
///
/// **Output**
/// - `donuts` (TableData) — same 14-column schema as `HoughCircleProcessor` and `WaveletDonutProcessor`.
public struct RingSearchProcessor: Processor {

    public var id: String { "ring_search" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        let minResponse        = Float(parameters["min_response"]?.doubleValue        ?? 0.0002)
        let nmsRadius          = parameters["nms_radius"]?.intValue                   ?? 20
        let maxDonuts          = parameters["max_donuts"]?.intValue                   ?? 50
        let sigmaRatioInner    = parameters["sigma_ratio_inner"]?.doubleValue         ?? 0.8
        let sigmaRatioOuter    = parameters["sigma_ratio_outer"]?.doubleValue         ?? 1.2
        _ = parameters["inner_center_search_r"]  // reserved for future per-donut refinement

        // --- Read reference geometry ---
        guard let refTable = inputs["reference_donut"] as? TableData,
              let df = refTable.dataFrame,
              df.rows.count > 0 else {
            Logger.processor.error("RingSearchProcessor: reference_donut table is missing or empty — writing empty donuts table so downstream steps can still run")
            try writeDonutsTable(outputs: &outputs, donuts: [])
            return
        }

        guard let outerRCol = df["outer_r"] as? AnyColumn,
              let outerR64  = outerRCol[0] as? Double,
              outerR64 > 0 else {
            Logger.processor.error("RingSearchProcessor: could not read outer_r from reference_donut")
            return
        }
        let outerR = outerR64

        // Use r_ratio from reference if available, otherwise use physics-based default.
        let rRatio: Double
        if let rRatioCol = df["r_ratio"] as? AnyColumn,
           let rr = rRatioCol[0] as? Double, rr > 0 {
            rRatio = rr
        } else {
            rRatio = 0.4
        }
        let innerR = outerR * rRatio

        // The collimation offset (secondary mirror displacement) is a property of the
        // telescope, not the individual star — it is identical for every donut in the
        // image.  Phase 1 measured it reliably on the bright donut.  We apply this
        // reference offset to all Phase 2 detections instead of trying to re-derive it
        // from faint donuts where the shadow is indistinguishable from sky background.
        let refOffsetX: Double
        let refOffsetY: Double
        if let oxCol = df["offset_x"] as? AnyColumn, let ox = oxCol[0] as? Double,
           let oyCol = df["offset_y"] as? AnyColumn, let oy = oyCol[0] as? Double {
            refOffsetX = ox
            refOffsetY = oy
        } else {
            refOffsetX = 0
            refOffsetY = 0
        }
        let refMsg = "RingSearchProcessor: reference offset (\(String(format:"%.1f",refOffsetX)), \(String(format:"%.1f",refOffsetY))) inner_r=\(String(format:"%.1f",innerR))"
        Logger.processor.debug("\(refMsg)")

        let W = inputTexture.width
        let H = inputTexture.height

        // NMS radius must be at least 2 × outer_r.
        //
        // The DoG response peaks both at the true ring centre AND on the ring
        // circumference itself (ring pixels at distance outer_r from the centre).
        // To guarantee that the true centre (highest response) suppresses ALL
        // ring-circumference peaks, the suppression zone must reach beyond outer_r.
        // Using 2 × outer_r also enforces the physical constraint that two separate
        // donuts cannot overlap — their centres must be at least 2 × outer_r apart.
        let effectiveNMSRadius = max(nmsRadius, Int((outerR * 2.0).rounded()))

        let rsLogMsg = "RingSearchProcessor: outer_r=\(String(format:"%.1f",outerR)) r_ratio=\(String(format:"%.2f",rRatio)) nms_radius=\(effectiveNMSRadius) image \(W)×\(H)"
        Logger.processor.debug("\(rsLogMsg)")

        // --- GPU pipeline states ---
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let hFn   = library.makeFunction(name: "gaussian_blur_horizontal"),
              let vFn   = library.makeFunction(name: "gaussian_blur_vertical"),
              let subFn = library.makeFunction(name: "subtract_textures") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "RingSearchProcessor: required shader functions not found")
        }
        let hPSO   = try ProcessorHelpers.createComputePipelineState(function: hFn,   device: device)
        let vPSO   = try ProcessorHelpers.createComputePipelineState(function: vFn,   device: device)
        let subPSO = try ProcessorHelpers.createComputePipelineState(function: subFn, device: device)

        // --- Texture pool (5 textures, same pattern as WaveletDonutProcessor) ---
        func makeFloat(_ w: Int, _ h: Int) throws -> MTLTexture {
            let desc = ProcessorHelpers.createTextureDescriptor(pixelFormat: .r32Float, width: w, height: h)
            return try ProcessorHelpers.createTexture(descriptor: desc, device: device)
        }
        let blurTempA = try makeFloat(W, H)
        let blurInner = try makeFloat(W, H)
        let blurTempB = try makeFloat(W, H)
        let blurOuter = try makeFloat(W, H)
        let dogTex    = try makeFloat(W, H)

        // --- Compute DoG at the reference radius ---
        let maxRadius    = Float(min(W, H) / 2 - 1)
        let radiusInner  = min(Float(outerR * sigmaRatioInner * 2.0), maxRadius)
        let radiusOuter  = min(Float(outerR * sigmaRatioOuter * 2.0), maxRadius)

        try dispatchBlur(input: inputTexture, temp: blurTempA, output: blurInner,
                         radius: radiusInner, hPSO: hPSO, vPSO: vPSO,
                         device: device, commandQueue: commandQueue)
        try dispatchBlur(input: inputTexture, temp: blurTempB, output: blurOuter,
                         radius: radiusOuter, hPSO: hPSO, vPSO: vPSO,
                         device: device, commandQueue: commandQueue)
        try dispatchSubtract(texA: blurInner, texB: blurOuter, output: dogTex,
                             subPSO: subPSO, device: device, commandQueue: commandQueue)

        // --- Read DoG to CPU ---
        var dogPixels = [Float](repeating: 0, count: W * H)
        dogTex.getBytes(&dogPixels,
                        bytesPerRow: W * MemoryLayout<Float>.stride,
                        from: MTLRegionMake2D(0, 0, W, H),
                        mipmapLevel: 0)

        // --- Read original pixels for inner centre refinement ---
        var pixels = [Float](repeating: 0, count: W * H)
        inputTexture.getBytes(&pixels,
                              bytesPerRow: W * MemoryLayout<Float>.stride,
                              from: MTLRegionMake2D(0, 0, W, H),
                              mipmapLevel: 0)

        // Compute the max positive DoG value for diagnostic logging and adaptive thresholding.
        // With large blur radii (outer_r can be 60-120px) the absolute DoG values are small,
        // so min_response as an absolute cut would kill all peaks.  We use the larger of:
        //   • the user-supplied min_response (absolute floor), and
        //   • 5% of the image-level DoG maximum (relative floor).
        // The relative floor ensures we always find the strongest peaks even when the DoG
        // amplitude is much smaller than expected.
        var maxDoG: Float = 0
        for v in dogPixels { if v > maxDoG { maxDoG = v } }
        // The faintest donuts can be ~1/300th the intensity of the brightest, so the relative
        // floor must be well below 1/300 = 0.33%.  Use 0.01% to give some margin.
        let relativeFloor = maxDoG * 0.0001
        // The absolute floor (min_response parameter) is intentionally ignored here —
        // it cannot be calibrated in advance because DoG amplitude depends on blur radius
        // and image normalisation.  The relative floor alone is sufficient: any real ring
        // at 1/300th the brightness of the brightest donut produces a DoG peak at 0.33%
        // of maxDoG, well above the 0.01% relative floor.
        let effectiveMinResponse = relativeFloor
        let dogMsg = "RingSearchProcessor: DoG max=\(String(format:"%.5f",maxDoG)) absolute_floor=\(String(format:"%.5f",minResponse)) relative_floor=\(String(format:"%.5f",relativeFloor)) using=\(String(format:"%.5f",effectiveMinResponse))"
        Logger.processor.debug("\(dogMsg)")

        // --- Find 2D peaks ---
        let peaks = findPeaks2D(dogPixels: dogPixels, W: W, H: H,
                                nmsRadius: effectiveNMSRadius, minResponse: effectiveMinResponse,
                                maxDonuts: maxDonuts)
        Logger.processor.debug("RingSearchProcessor: \(peaks.count) peaks found")

        // --- Refine inner centre per donut ---
        // Strategy: the reference offset gives a good predicted inner-centre position.
        // We do a local intensity-weighted centroid of dark pixels in a small search
        // window around that predicted position.  Local contrast works even for faint
        // donuts — the shadow is always the darkest region within innerR of the centre,
        // regardless of the absolute brightness of the ring.
        var donuts: [DonutRecord] = []
        for (cx, cy, response) in peaks {
            // Refine outer centre: DoG-weighted centroid in a window of outerR/3 around
            // the integer peak pixel.  The DoG blob is ~outerR wide, so the centroid is
            // far more accurate than the raw peak coordinate.
            let (outerCX, outerCY) = refineOuterCenterLocal(
                dogPixels: dogPixels, W: W, H: H,
                peakX: cx, peakY: cy, outerR: outerR,
                pixels: pixels
            )
            let (innerCX, innerCY) = refineInnerCenterLocal(
                pixels: pixels, W: W, H: H,
                predictedCX: outerCX + refOffsetX,
                predictedCY: outerCY + refOffsetY,
                outerCX: outerCX, outerCY: outerCY,
                innerR: innerR
            )
            donuts.append(DonutRecord(
                outerCX: outerCX, outerCY: outerCY, outerR: outerR,
                outerVotes: Int(response * 10000),
                innerCX: innerCX, innerCY: innerCY, innerR: innerR
            ))
        }

        Logger.processor.info("RingSearchProcessor: \(donuts.count) donuts detected")
        try writeDonutsTable(outputs: &outputs, donuts: donuts)
    }

    // MARK: - 2D Peak Finding with NMS

    private func findPeaks2D(
        dogPixels: [Float], W: Int, H: Int,
        nmsRadius: Int, minResponse: Float,
        maxDonuts: Int
    ) -> [(x: Int, y: Int, response: Float)] {
        let margin = nmsRadius
        var candidates: [(x: Int, y: Int, v: Float)] = []
        for y in margin..<(H - margin) {
            for x in margin..<(W - margin) {
                let v = dogPixels[y * W + x]
                if v >= minResponse { candidates.append((x, y, v)) }
            }
        }
        // Sort descending by response for greedy NMS
        let sorted = candidates.sorted { $0.v > $1.v }
        var kept: [(x: Int, y: Int, response: Float)] = []
        var suppressed = [Bool](repeating: false, count: sorted.count)

        for i in 0..<sorted.count {
            if suppressed[i] { continue }
            let (cx, cy, cv) = (sorted[i].x, sorted[i].y, sorted[i].v)
            kept.append((cx, cy, cv))
            if kept.count >= maxDonuts { break }
            // Suppress nearby candidates (use <= so peaks exactly at nmsRadius are suppressed)
            for j in (i+1)..<sorted.count {
                if suppressed[j] { continue }
                let dx = sorted[j].x - cx, dy = sorted[j].y - cy
                let dist2 = dx*dx + dy*dy
                if dist2 <= nmsRadius * nmsRadius {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    // MARK: - GPU Dispatch Helpers

    private func dispatchBlur(
        input: MTLTexture, temp: MTLTexture, output: MTLTexture,
        radius: Float,
        hPSO: MTLComputePipelineState, vPSO: MTLComputePipelineState,
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) throws {
        var r = radius
        let radiusBuffer = try ProcessorHelpers.createBuffer(from: &r, device: device)
        let cb  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb)

        enc.setComputePipelineState(hPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(temp,  index: 1)
        enc.setBuffer(radiusBuffer, offset: 0, index: 0)
        let (tgSize, tgCount) = ProcessorHelpers.calculateThreadgroups(for: input)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

        enc.setComputePipelineState(vPSO)
        enc.setTexture(temp,   index: 0)
        enc.setTexture(output, index: 1)
        enc.setBuffer(radiusBuffer, offset: 0, index: 0)
        let (tgSize2, tgCount2) = ProcessorHelpers.calculateThreadgroups(for: temp)
        enc.dispatchThreadgroups(tgCount2, threadsPerThreadgroup: tgSize2)

        enc.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb)
    }

    private func dispatchSubtract(
        texA: MTLTexture, texB: MTLTexture, output: MTLTexture,
        subPSO: MTLComputePipelineState,
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) throws {
        let cb  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb)
        enc.setComputePipelineState(subPSO)
        enc.setTexture(texA,   index: 0)
        enc.setTexture(texB,   index: 1)
        enc.setTexture(output, index: 2)
        let (tgSize, tgCount) = ProcessorHelpers.calculateThreadgroups(for: output)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb)
    }

    // MARK: - Inner Centre Refinement (shared logic with WaveletDonutProcessor)

    private func refineInnerCenter(
        pixels: [Float], W: Int, H: Int,
        outerCX: Double, outerCY: Double,
        outerR: Double, estimatedInnerR: Double,
        innerCenterSearchR: Double
    ) -> (cx: Double, cy: Double, innerR: Double) {
        let searchRadius = estimatedInnerR * (1.0 + innerCenterSearchR)
        let ringBand     = max(2.0, outerR * 0.1)

        let boxR = Int(outerR + ringBand + 1)
        let xLo = max(0, Int(outerCX) - boxR), xHi = min(W - 1, Int(outerCX) + boxR)
        let yLo = max(0, Int(outerCY) - boxR), yHi = min(H - 1, Int(outerCY) + boxR)

        var centreSum = 0.0, centreCount = 0
        var ringSum   = 0.0, ringCount   = 0
        for py in yLo...yHi {
            let dy = Double(py) - outerCY
            for px in xLo...xHi {
                let dx   = Double(px) - outerCX
                let dist = sqrt(dx*dx + dy*dy)
                let v    = Double(pixels[py * W + px])
                if dist <= 2.0                                              { centreSum += v; centreCount += 1 }
                if dist >= outerR - ringBand && dist <= outerR + ringBand   { ringSum   += v; ringCount   += 1 }
            }
        }
        let centreVal       = centreCount > 0 ? centreSum / Double(centreCount) : 0.0
        let ringVal         = ringCount   > 0 ? ringSum   / Double(ringCount)   : centreVal * 2.0
        let shadowThreshold = centreVal + 0.3 * (ringVal - centreVal)

        let sxLo = max(0, Int(outerCX - searchRadius - 1))
        let sxHi = min(W - 1, Int(outerCX + searchRadius + 1))
        let syLo = max(0, Int(outerCY - searchRadius - 1))
        let syHi = min(H - 1, Int(outerCY + searchRadius + 1))

        var sumWX = 0.0, sumWY = 0.0, totalW = 0.0
        var darkDistSum = 0.0, darkDistCount = 0
        for py in syLo...syHi {
            let dy = Double(py) - outerCY
            for px in sxLo...sxHi {
                let dx   = Double(px) - outerCX
                guard sqrt(dx*dx + dy*dy) <= searchRadius else { continue }
                let v = Double(pixels[py * W + px])
                guard v < shadowThreshold else { continue }
                let weight  = shadowThreshold - v
                sumWX      += weight * Double(px)
                sumWY      += weight * Double(py)
                totalW     += weight
                darkDistSum   += sqrt(dx*dx + dy*dy)
                darkDistCount += 1
            }
        }
        guard totalW > 0 else { return (outerCX, outerCY, estimatedInnerR) }
        let innerCX = sumWX / totalW
        let innerCY = sumWY / totalW
        let innerR  = darkDistCount > 0 ? darkDistSum / Double(darkDistCount) : estimatedInnerR
        return (innerCX, innerCY, innerR)
    }

    /// Refines the outer ring centre by grid search maximising mean intensity along
    /// a circle of radius `outerR`.  This is rotation-invariant and unaffected by
    /// asymmetric ring brightness (collimation offset makes one arc brighter, which
    /// biases a DoG centroid but does not bias a ring-mean score).
    ///
    /// Search: coarse grid ±outerR/4 at outerR/8 steps, then fine grid ±outerR/8 at
    /// outerR/16 steps around the coarse best.  Evaluates ~(9×9 + 9×9) = ~162 candidates.
    private func refineOuterCenterLocal(
        dogPixels: [Float], W: Int, H: Int,
        peakX: Int, peakY: Int, outerR: Double,
        pixels: [Float]
    ) -> (cx: Double, cy: Double) {
        let bandwidth = max(2.0, outerR * 0.12)   // ring annulus ±bandwidth around outerR

        func ringScore(cx: Double, cy: Double) -> Double {
            let r1 = outerR - bandwidth, r2 = outerR + bandwidth
            let r1sq = r1 * r1, r2sq = r2 * r2
            let boxR = Int(r2 + 1)
            let xLo = max(0, Int(cx) - boxR), xHi = min(W - 1, Int(cx) + boxR)
            let yLo = max(0, Int(cy) - boxR), yHi = min(H - 1, Int(cy) + boxR)
            var sum = 0.0, count = 0
            for py in yLo...yHi {
                let dy = Double(py) - cy
                let dy2 = dy * dy
                if dy2 > r2sq { continue }
                for px in xLo...xHi {
                    let dx = Double(px) - cx
                    let d2 = dx*dx + dy2
                    if d2 >= r1sq && d2 <= r2sq {
                        sum += Double(pixels[py * W + px])
                        count += 1
                    }
                }
            }
            return count > 0 ? sum / Double(count) : 0
        }

        var bestX = Double(peakX), bestY = Double(peakY)

        // Coarse pass
        let coarseStep = outerR / 8.0
        let coarseRange = outerR / 4.0
        var bestScore = ringScore(cx: bestX, cy: bestY)
        var stride = -coarseRange
        while stride <= coarseRange {
            var strideY = -coarseRange
            while strideY <= coarseRange {
                let cx = Double(peakX) + stride
                let cy = Double(peakY) + strideY
                let s = ringScore(cx: cx, cy: cy)
                if s > bestScore { bestScore = s; bestX = cx; bestY = cy }
                strideY += coarseStep
            }
            stride += coarseStep
        }

        // Fine pass around coarse best
        let fineStep = outerR / 16.0
        let fineRange = outerR / 8.0
        let coarseBestX = bestX, coarseBestY = bestY
        stride = -fineRange
        while stride <= fineRange {
            var strideY = -fineRange
            while strideY <= fineRange {
                let cx = coarseBestX + stride
                let cy = coarseBestY + strideY
                let s = ringScore(cx: cx, cy: cy)
                if s > bestScore { bestScore = s; bestX = cx; bestY = cy }
                strideY += fineStep
            }
            stride += fineStep
        }

        return (bestX, bestY)
    }

    /// Refines the inner shadow centre using local contrast around a predicted position.
    ///
    /// Instead of thresholding against global ring brightness (which fails for faint donuts
    /// where ring ≈ sky), we use the local minimum inside `innerR` as the contrast anchor.
    /// The predicted position from Phase 1 is used as seed; the result is the
    /// intensity-weighted centroid of pixels darker than the local mean within the search window.
    private func refineInnerCenterLocal(
        pixels: [Float], W: Int, H: Int,
        predictedCX: Double, predictedCY: Double,
        outerCX: Double, outerCY: Double,
        innerR: Double
    ) -> (cx: Double, cy: Double) {
        // Search within innerR of the predicted position
        let searchR = innerR * 1.5
        let xLo = max(0, Int((predictedCX - searchR).rounded()))
        let xHi = min(W - 1, Int((predictedCX + searchR).rounded()))
        let yLo = max(0, Int((predictedCY - searchR).rounded()))
        let yHi = min(H - 1, Int((predictedCY + searchR).rounded()))

        guard xLo <= xHi, yLo <= yHi else { return (predictedCX, predictedCY) }

        // Collect pixel values in the window
        var localMin: Float = .greatestFiniteMagnitude
        var localSum: Float = 0
        var localCount = 0
        for py in yLo...yHi {
            let dy = Double(py) - predictedCY
            for px in xLo...xHi {
                let dx = Double(px) - predictedCX
                guard dx*dx + dy*dy <= searchR*searchR else { continue }
                let v = pixels[py * W + px]
                localSum   += v
                localCount += 1
                if v < localMin { localMin = v }
            }
        }
        guard localCount > 0 else { return (predictedCX, predictedCY) }
        let localMean = Double(localSum) / Double(localCount)
        let threshold = Double(localMin) + 0.4 * (localMean - Double(localMin))

        // Intensity-weighted centroid of pixels below threshold
        var sumWX = 0.0, sumWY = 0.0, totalW = 0.0
        for py in yLo...yHi {
            let dy = Double(py) - predictedCY
            for px in xLo...xHi {
                let dx = Double(px) - predictedCX
                guard dx*dx + dy*dy <= searchR*searchR else { continue }
                let v = Double(pixels[py * W + px])
                guard v < threshold else { continue }
                let w   = threshold - v
                sumWX  += w * Double(px)
                sumWY  += w * Double(py)
                totalW += w
            }
        }
        guard totalW > 0 else { return (predictedCX, predictedCY) }
        return (sumWX / totalW, sumWY / totalW)
    }

    // MARK: - Output Writing

    private struct DonutRecord {
        let outerCX: Double, outerCY: Double, outerR: Double, outerVotes: Int
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
        df.append(column: Column(name: "outer_votes",      contents: donuts.map(\.outerVotes)))
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
        df.append(column: Column(name: "r_ratio",          contents: donuts.map {
            $0.outerR > 0 ? $0.innerR / $0.outerR : 0.0
        }))
        table.dataFrame = df
        outputs["donuts"] = table
    }
}
