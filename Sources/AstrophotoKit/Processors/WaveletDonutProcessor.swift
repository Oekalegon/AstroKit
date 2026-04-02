import Foundation
import Metal
import TabularData
import os

/// Processor that detects donut-shaped out-of-focus star images using a
/// Difference-of-Gaussians (DoG) scale-space approach on the GPU.
///
/// For each scale radius `r` in `[r_min, r_max]` stepped by `scale_step`:
///   1. Computes `DoG(r) = blur(r × sigma_inner) - blur(r × sigma_outer)` on the GPU.
///      The DoG acts as a Mexican-hat wavelet that responds maximally to bright rings
///      at radius ~r surrounded by darker background.
///   2. Finds 2D local maxima above `min_response` in the DoG image (CPU).
///   3. Collects all scale-space peaks, then applies 3D NMS (spatial + scale).
///   4. For each surviving peak, refines the inner shadow centre via an
///      intensity-weighted centroid of dark pixels — giving the collimation offset.
///
/// No connected-components pre-detection needed. The pipeline is simply:
///   grayscale → wavelet_donut → collimation_analysis → overlay
///
/// **Input**
/// - `input_frame` (Frame) — greyscale r32Float image
///
/// **Parameters**
/// - `r_min`               Int    (default  20) — minimum ring radius (pixels)
/// - `r_max`               Int    (default 150) — maximum ring radius (pixels)
/// - `scale_step`          Int    (default  10) — step between tested scales
/// - `sigma_ratio_inner`   Double (default 0.8) — inner Gaussian sigma = r × ratio
/// - `sigma_ratio_outer`   Double (default 1.2) — outer Gaussian sigma = r × ratio
/// - `min_response`        Double (default 0.005) — minimum DoG peak value
/// - `nms_radius`          Int    (default  20) — spatial NMS radius (pixels)
/// - `nms_scale_radius`    Int    (default   1) — cross-scale NMS radius (in scale steps)
/// - `max_donuts`          Int    (default  50) — maximum donuts to return
/// - `inner_center_search_r` Double (default 0.5) — inner search radius as fraction of inner_r
///
/// **Output**
/// - `donuts` (TableData) — same 14-column schema as `HoughCircleProcessor`
public struct WaveletDonutProcessor: Processor {

    public var id: String { "wavelet_donut" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        let rMin               = parameters["r_min"]?.intValue                    ?? 20
        let rMax               = parameters["r_max"]?.intValue                    ?? 150
        let scaleStep          = max(1, parameters["scale_step"]?.intValue        ?? 10)
        let sigmaRatioInner    = parameters["sigma_ratio_inner"]?.doubleValue     ?? 0.8
        let sigmaRatioOuter    = parameters["sigma_ratio_outer"]?.doubleValue     ?? 1.2
        let minResponse        = Float(parameters["min_response"]?.doubleValue    ?? 0.002)
        let nmsRadius          = parameters["nms_radius"]?.intValue               ?? 20
        let nmsScaleRadius     = parameters["nms_scale_radius"]?.intValue         ?? 4
        let maxDonuts          = parameters["max_donuts"]?.intValue               ?? 50
        let innerCenterSearchR = parameters["inner_center_search_r"]?.doubleValue ?? 0.5

        guard rMin > 0, rMax >= rMin else {
            throw ProcessorExecutionError.executionFailed("r_min must be > 0 and r_max >= r_min")
        }

        let W = inputTexture.width
        let H = inputTexture.height

        let estimatedBytes = 5 * W * H * MemoryLayout<Float>.stride
        guard estimatedBytes <= 600 * 1024 * 1024 else {
            throw ProcessorExecutionError.executionFailed(
                "Image too large for WaveletDonutProcessor: \(estimatedBytes / (1024*1024)) MB needed for texture pool")
        }

        let logMsg = "WaveletDonutProcessor: r_min=\(rMin) r_max=\(rMax) step=\(scaleStep) image \(W)×\(H)"
        Logger.processor.debug("\(logMsg)")

        // MARK: - CPU pixel buffer (read once, used for inner centre refinement)

        var pixels = [Float](repeating: 0, count: W * H)
        inputTexture.getBytes(
            &pixels,
            bytesPerRow: W * MemoryLayout<Float>.stride,
            from: MTLRegionMake2D(0, 0, W, H),
            mipmapLevel: 0
        )

        // MARK: - Pipeline states (created once, reused across all scale dispatches)

        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let hFn   = library.makeFunction(name: "gaussian_blur_horizontal"),
              let vFn   = library.makeFunction(name: "gaussian_blur_vertical"),
              let subFn = library.makeFunction(name: "subtract_textures") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load required shader functions (gaussian_blur_horizontal/vertical, subtract_textures)")
        }
        let hPSO   = try ProcessorHelpers.createComputePipelineState(function: hFn,   device: device)
        let vPSO   = try ProcessorHelpers.createComputePipelineState(function: vFn,   device: device)
        let subPSO = try ProcessorHelpers.createComputePipelineState(function: subFn, device: device)

        // MARK: - Texture pool (5 textures, allocated once, reused each scale)

        let blurTempA = try makeR32FloatTexture(width: W, height: H, device: device)
        let blurInner = try makeR32FloatTexture(width: W, height: H, device: device)
        let blurTempB = try makeR32FloatTexture(width: W, height: H, device: device)
        let blurOuter = try makeR32FloatTexture(width: W, height: H, device: device)
        let dogTex    = try makeR32FloatTexture(width: W, height: H, device: device)

        // MARK: - Scale-space sweep

        let scales = Swift.stride(from: rMin, through: rMax, by: scaleStep).map { $0 }
        var allPeaks: [WaveletPeak] = []
        var dogPixels = [Float](repeating: 0, count: W * H)

        for r in scales {
            // sigma = radius/2  →  radius = sigma*2
            // cap radius to avoid kernel size exceeding half the image
            let maxRadius = Float(min(W, H) / 2 - 1)
            let radiusInner = min(Float(Double(r) * sigmaRatioInner * 2.0), maxRadius)
            let radiusOuter = min(Float(Double(r) * sigmaRatioOuter * 2.0), maxRadius)

            // Blur at inner sigma: inputTexture → blurTempA → blurInner
            try dispatchBlur(input: inputTexture, temp: blurTempA, output: blurInner,
                             radius: radiusInner, hPSO: hPSO, vPSO: vPSO,
                             device: device, commandQueue: commandQueue)

            // Blur at outer sigma: inputTexture → blurTempB → blurOuter
            try dispatchBlur(input: inputTexture, temp: blurTempB, output: blurOuter,
                             radius: radiusOuter, hPSO: hPSO, vPSO: vPSO,
                             device: device, commandQueue: commandQueue)

            // DoG = blurInner - blurOuter
            try dispatchSubtract(texA: blurInner, texB: blurOuter, output: dogTex,
                                 subPSO: subPSO, device: device, commandQueue: commandQueue)

            // Read DoG to CPU
            dogTex.getBytes(
                &dogPixels,
                bytesPerRow: W * MemoryLayout<Float>.stride,
                from: MTLRegionMake2D(0, 0, W, H),
                mipmapLevel: 0
            )

            // Find 2D peaks in this DoG slice
            let peaks = findPeaks2D(dogPixels: dogPixels, W: W, H: H,
                                    nmsRadius: nmsRadius, minResponse: minResponse)
            let scaleMsg = "WaveletDonutProcessor: r=\(r) — \(peaks.count) peaks"
            Logger.processor.debug("\(scaleMsg)")

            for (x, y, response) in peaks {
                allPeaks.append(WaveletPeak(x: x, y: y, r: r, response: response))
            }
        }

        Logger.processor.debug("WaveletDonutProcessor: \(allPeaks.count) total peaks before 3D NMS")

        // MARK: - 3D NMS across scales

        let keptPeaks = nms3D(peaks: allPeaks, nmsRadius: nmsRadius,
                              nmsScaleRadius: nmsScaleRadius, scaleStep: scaleStep,
                              maxDonuts: maxDonuts)

        Logger.processor.debug("WaveletDonutProcessor: \(keptPeaks.count) peaks after 3D NMS")

        // MARK: - Inner centre refinement

        var donuts: [DonutRecord] = []
        for peak in keptPeaks {
            let outerCX = Double(peak.x)
            let outerCY = Double(peak.y)
            let outerR  = Double(peak.r)
            let innerR  = outerR * 0.4   // physical prior for secondary mirror ratio

            let (innerCX, innerCY, measuredInnerR) = refineInnerCenter(
                pixels: pixels, W: W, H: H,
                outerCX: outerCX, outerCY: outerCY,
                outerR: outerR, estimatedInnerR: innerR,
                innerCenterSearchR: innerCenterSearchR
            )

            donuts.append(DonutRecord(
                outerCX: outerCX,   outerCY: outerCY,   outerR: outerR,
                outerVotes: Int(peak.response * 10000),
                innerCX: innerCX,   innerCY: innerCY,   innerR: measuredInnerR
            ))
        }

        Logger.processor.info("WaveletDonutProcessor: \(donuts.count) donuts detected")
        try writeDonutsTable(outputs: &outputs, donuts: donuts)
    }

    // MARK: - GPU Dispatch Helpers

    private func makeR32FloatTexture(width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        let desc = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: .r32Float, width: width, height: height)
        return try ProcessorHelpers.createTexture(descriptor: desc, device: device)
    }

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

        // Horizontal pass: input → temp
        enc.setComputePipelineState(hPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(temp,  index: 1)
        enc.setBuffer(radiusBuffer, offset: 0, index: 0)
        let (tgSize, tgCount) = ProcessorHelpers.calculateThreadgroups(for: input)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

        // Vertical pass: temp → output (same encoder, same command buffer)
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

    // MARK: - 2D Peak Finding

    /// Finds local maxima in a DoG image using a two-pass candidate approach.
    /// Returns (x, y, response) tuples.
    private func findPeaks2D(
        dogPixels: [Float], W: Int, H: Int,
        nmsRadius: Int, minResponse: Float
    ) -> [(Int, Int, Float)] {
        // Pass 1: collect candidates above threshold (sparse in practice)
        var candidates: [(x: Int, y: Int, v: Float)] = []
        let margin = nmsRadius
        for y in margin..<(H - margin) {
            for x in margin..<(W - margin) {
                let v = dogPixels[y * W + x]
                if v >= minResponse { candidates.append((x, y, v)) }
            }
        }

        // Pass 2: keep only local maxima (no neighbour in nmsRadius window has higher value)
        var peaks: [(Int, Int, Float)] = []
        for (cx, cy, cv) in candidates {
            var isMax = true
            outer: for dy in -nmsRadius...nmsRadius {
                for dx in -nmsRadius...nmsRadius {
                    if dx == 0 && dy == 0 { continue }
                    let nx = cx + dx, ny = cy + dy
                    if dogPixels[ny * W + nx] > cv { isMax = false; break outer }
                }
            }
            if isMax { peaks.append((cx, cy, cv)) }
        }
        return peaks
    }

    // MARK: - 3D NMS

    private struct WaveletPeak {
        let x: Int, y: Int, r: Int
        let response: Float
    }

    private func nms3D(
        peaks: [WaveletPeak],
        nmsRadius: Int, nmsScaleRadius: Int, scaleStep: Int,
        maxDonuts: Int
    ) -> [WaveletPeak] {
        // Score = response × r: strongly prefers large-radius peaks (outer ring) over
        // small-radius peaks (inner shadow edge) when both are near the same center.
        let sorted = peaks.sorted { ($0.response * Float($0.r)) > ($1.response * Float($1.r)) }
        var kept: [WaveletPeak] = []

        for peak in sorted {
            let suppressed = kept.contains { k in
                let dx = Double(peak.x - k.x), dy = Double(peak.y - k.y)
                let spatialDist = sqrt(dx*dx + dy*dy)
                let scaleDistSteps = abs(peak.r - k.r) / scaleStep
                return spatialDist < Double(nmsRadius) && scaleDistSteps <= nmsScaleRadius
            }
            if !suppressed {
                kept.append(peak)
                if kept.count >= maxDonuts { break }
            }
        }
        return kept
    }

    // MARK: - Inner Centre Refinement

    private struct DonutRecord {
        let outerCX: Double, outerCY: Double, outerR: Double, outerVotes: Int
        let innerCX: Double, innerCY: Double, innerR: Double
    }

    /// Intensity-weighted centroid of dark pixels in the secondary shadow region.
    /// Returns (innerCX, innerCY, innerR).
    private func refineInnerCenter(
        pixels: [Float],
        W: Int, H: Int,
        outerCX: Double, outerCY: Double,
        outerR: Double, estimatedInnerR: Double,
        innerCenterSearchR: Double
    ) -> (cx: Double, cy: Double, innerR: Double) {
        let searchRadius = estimatedInnerR * (1.0 + innerCenterSearchR)

        // Profile values for shadow threshold
        var centreSum = 0.0, centreCount = 0
        var ringSum   = 0.0, ringCount   = 0
        let ringBand  = max(2.0, outerR * 0.1)

        let boxR = Int(outerR + ringBand + 1)
        let xLo = max(0, Int(outerCX) - boxR), xHi = min(W - 1, Int(outerCX) + boxR)
        let yLo = max(0, Int(outerCY) - boxR), yHi = min(H - 1, Int(outerCY) + boxR)

        for py in yLo...yHi {
            let dy = Double(py) - outerCY
            for px in xLo...xHi {
                let dx = Double(px) - outerCX
                let dist = sqrt(dx*dx + dy*dy)
                let v = Double(pixels[py * W + px])
                if dist <= 2.0                            { centreSum += v; centreCount += 1 }
                if dist >= outerR - ringBand && dist <= outerR + ringBand { ringSum += v; ringCount += 1 }
            }
        }

        let centreVal = centreCount > 0 ? centreSum / Double(centreCount) : 0.0
        let ringVal   = ringCount   > 0 ? ringSum   / Double(ringCount)   : centreVal * 2.0
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
                let dx = Double(px) - outerCX
                guard sqrt(dx*dx + dy*dy) <= searchRadius else { continue }
                let v = Double(pixels[py * W + px])
                guard v < shadowThreshold else { continue }
                let weight = shadowThreshold - v
                sumWX  += weight * Double(px)
                sumWY  += weight * Double(py)
                totalW += weight
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

    // MARK: - Output Writing

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
