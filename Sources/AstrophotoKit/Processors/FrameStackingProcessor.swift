import Foundation
import Metal
import TabularData
import os

// MARK: - Internal types

private struct SimilarityTransform {
    let tx: Double
    let ty: Double
    let rotation: Double  // radians
    let scale: Double

    var a: Double { scale * cos(rotation) }
    var b: Double { scale * sin(rotation) }

    static let identity = SimilarityTransform(tx: 0, ty: 0, rotation: 0, scale: 1)
}

private struct FrameStats {
    let background: Float
    let scale: Float
    let std: Float
}

// Swift mirrors of the Metal structs — layout must stay in sync with StackShader.metal
private struct StackParams {
    var nFrames:   UInt32
    var stackMode: UInt32  // 0=average 1=sum 2=median 3=max_pixel 4=min_pixel
    var rejMode:   UInt32  // 0=none 1=sigma_clip 2=winsorized
    var rejLow:    Float
    var rejHigh:   Float
}

private struct FrameNorm {
    var mulFactor: Float
    var addOffset: Float
}

// Must match STACK_MAX_FRAMES in StackShader.metal
private let stackMaxFrames = 128

// MARK: - Processor

public struct FrameStackingProcessor: Processor {
    public var id: String { "frame_stacking" }
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
        guard let regTableData = inputs["registration_table"] as? TableData,
              let regDF = regTableData.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("registration_table")
        }

        let method  = parameters["method"]?.stringValue          ?? "average"
        let normStr = parameters["normalisation"]?.stringValue    ?? "none"
        let rejStr  = parameters["pixel_rejection"]?.stringValue  ?? "sigma_clip"
        let rejLow  = Float(parameters["rejection_low"]?.doubleValue  ?? 3.0)
        let rejHigh = Float(parameters["rejection_high"]?.doubleValue ?? 3.0)

        guard let refTexture = frameSet.frames.first?.texture else {
            throw ProcessorExecutionError.executionFailed("First frame has no texture")
        }
        let width   = refTexture.width
        let height  = refTexture.height
        let nFrames = frameSet.frames.count

        guard nFrames <= stackMaxFrames else {
            throw ProcessorExecutionError.executionFailed(
                "FrameStacking: \(nFrames) frames exceeds the GPU kernel limit of \(stackMaxFrames). " +
                "Split your input into smaller batches."
            )
        }

        Logger.processor.info(
            "FrameStacking: \(nFrames) frames \(width)×\(height), method=\(method) norm=\(normStr) rejection=\(rejStr)"
        )

        // 1. Extract per-frame transforms from the registration table
        let transforms = extractTransforms(from: regDF, frameCount: nFrames)

        // 2. Warp every frame into the reference coordinate system (GPU, CPU fallback)
        var warpedTextures: [MTLTexture] = []
        warpedTextures.reserveCapacity(nFrames)
        for (i, frame) in frameSet.frames.enumerated() {
            let t = i < transforms.count ? transforms[i] : .identity
            let warped = try warpFrame(
                frame, transform: t, width: width, height: height,
                device: device, commandQueue: commandQueue
            )
            warpedTextures.append(warped)
        }

        // 2b. Alignment check — verify warped frames using reference star centroids
        let refIdx = transforms.firstIndex {
            abs($0.tx) < 0.5 && abs($0.ty) < 0.5 && abs($0.rotation) < 1e-4 && abs($0.scale - 1) < 1e-4
        } ?? 0
        let refStars: [(x: Double, y: Double)]
        if let refStarsData = inputs["reference_stars"] as? TableData, let refDF = refStarsData.dataFrame {
            refStars = refDF.rows.compactMap { row -> (x: Double, y: Double)? in
                guard let x = row["x"] as? Double, let y = row["y"] as? Double else { return nil }
                return (x, y)
            }
        } else {
            refStars = []
        }
        let alignResults = checkStarAlignment(warpedTextures: warpedTextures, referenceIndex: refIdx, referenceStars: refStars)

        // 3. Compute per-frame normalisation coefficients from pixel samples
        let normCoeffs = computeNormCoeffs(
            from: warpedTextures, method: normStr,
            device: device, commandQueue: commandQueue
        )

        // 4. Stack on GPU with normalisation and pixel rejection baked into the kernel
        let outTexture = try stackOnGPU(
            frames: warpedTextures, normCoeffs: normCoeffs,
            method: method, rejection: rejStr, rejLow: rejLow, rejHigh: rejHigh,
            width: width, height: height, device: device, commandQueue: commandQueue
        )

        // 5. Write texture into the existing placeholder Frame (preserves UUID for DataStack.update)
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "stacked_frame",
            texture: outTexture
        )

        // 6. Pass registration table through, augmented with per-frame star-alignment results.
        // Must mutate the existing placeholder (preserves its UUID for DataStack.update).
        let alignByFrame = Dictionary(uniqueKeysWithValues: alignResults.map {
            ($0.frameIndex, (residual: $0.meanResidual, matched: $0.matchedCount, missing: $0.missingCount))
        })
        var residualVals = [Double](), matchedVals = [Int](), missingVals = [Int]()
        for row in regDF.rows {
            let fi: Int
            if      let v = row["frame_index"] as? Int32 { fi = Int(v) }
            else if let v = row["frame_index"] as? Int   { fi = v }
            else                                          { fi = -1 }
            let a = alignByFrame[fi] ?? (residual: 0.0, matched: 0, missing: 0)
            residualVals.append(a.residual)
            matchedVals.append(a.matched)
            missingVals.append(a.missing)
        }
        var augmentedDF = regDF
        augmentedDF.append(column: Column<Double>(name: "align_residual", contents: residualVals))
        augmentedDF.append(column: Column<Int>(name: "align_matched",  contents: matchedVals))
        augmentedDF.append(column: Column<Int>(name: "align_missing",  contents: missingVals))
        if var outTable = outputs["stacked_registration_table"] as? TableData {
            outTable.dataFrame = augmentedDF
            outputs["stacked_registration_table"] = outTable
        }

        Logger.processor.info("FrameStacking: completed")
    }

    // MARK: - Transform extraction

    private func extractTransforms(from df: DataFrame, frameCount: Int) -> [SimilarityTransform] {
        var result = [SimilarityTransform](repeating: .identity, count: frameCount)
        for row in df.rows {
            // TabularData can bridge Int32 through NSNumber on macOS, so try both Int32 and Int.
            let i: Int
            if      let v = row["frame_index"] as? Int32 { i = Int(v) }
            else if let v = row["frame_index"] as? Int   { i = v }
            else                                          { continue }
            guard i >= 0, i < frameCount else { continue }

            // Similarly, Double columns may come back as Float on some paths.
            func dbl(_ key: String, fallback: Double = 0) -> Double {
                if let v = row[key] as? Double { return v }
                if let v = row[key] as? Float  { return Double(v) }
                return fallback
            }
            let tx     = dbl("translation_x")
            let ty     = dbl("translation_y")
            let rotDeg = dbl("rotation_deg")
            let scale  = dbl("scale", fallback: 1)
            result[i] = SimilarityTransform(tx: tx, ty: ty, rotation: rotDeg * .pi / 180, scale: scale)
        }
        return result
    }

    // MARK: - GPU warp (returns MTLTexture; CPU fallback writes into shared texture)

    private func warpFrame(
        _ frame: Frame,
        transform: SimilarityTransform,
        width: Int, height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        guard let src = frame.texture else {
            throw ProcessorExecutionError.executionFailed("Frame has no texture")
        }

        // Identity — return original texture directly
        if abs(transform.tx) < 1e-9 && abs(transform.ty) < 1e-9
            && abs(transform.rotation) < 1e-9 && abs(transform.scale - 1) < 1e-9 {
            return src
        }

        // GPU warp
        if let library = AstrophotoKit.makeShaderLibrary(device: device),
           let fn = library.makeFunction(name: "affine_warp"),
           let pipeline = try? device.makeComputePipelineState(function: fn) {
            return try gpuWarpTexture(src: src, transform: transform, width: width, height: height,
                                      device: device, commandQueue: commandQueue, pipeline: pipeline)
        }

        // CPU fallback — warp and write into a new texture
        Logger.processor.warning("FrameStacking: GPU warp unavailable, falling back to CPU")
        let srcPixels = readPixels(from: src, width: src.width, height: src.height)
        let warped = cpuWarp(pixels: srcPixels, srcW: src.width, srcH: src.height,
                             transform: transform, outW: width, outH: height)
        return try pixelsToTexture(warped, width: width, height: height, device: device)
    }

    private func gpuWarpTexture(
        src: MTLTexture,
        transform: SimilarityTransform,
        width: Int, height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLComputePipelineState
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let dst = device.makeTexture(descriptor: desc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create warp destination texture")
        }

        var params = SIMD4<Float>(
            Float(transform.a), Float(transform.b),
            Float(transform.tx), Float(transform.ty)
        )
        guard let buf = device.makeBuffer(bytes: &params,
                                          length: MemoryLayout<SIMD4<Float>>.size,
                                          options: .storageModeShared) else {
            throw ProcessorExecutionError.executionFailed("Failed to create warp params buffer")
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            throw ProcessorExecutionError.executionFailed("Failed to create compute command buffer")
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBuffer(buf, offset: 0, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let gc = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(gc, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return dst
    }

    private func cpuWarp(
        pixels: [Float], srcW: Int, srcH: Int,
        transform: SimilarityTransform, outW: Int, outH: Int
    ) -> [Float] {
        let a = transform.a, b = transform.b
        let tx = transform.tx, ty = transform.ty
        var out = [Float](repeating: -1, count: outW * outH)  // -1 = sentinel (out-of-bounds)
        for y in 0..<outH {
            for x in 0..<outW {
                let fx = Double(x), fy = Double(y)
                let sx = a * fx - b * fy + tx
                let sy = b * fx + a * fy + ty
                let cx = Int(floor(sx)), cy = Int(floor(sy))
                // Entire 4×4 Lanczos support outside source frame → keep sentinel
                if cx + 2 < 0 || cx - 1 >= srcW || cy + 2 < 0 || cy - 1 >= srcH { continue }
                if let v = lanczos2Sample(pixels, w: srcW, h: srcH, x: sx, y: sy) {
                    out[y * outW + x] = v
                }
            }
        }
        return out
    }

    // Lanczos-2 kernel: sinc(x)*sinc(x/2) for |x|<2
    private func lanczos2Weight(_ x: Double) -> Double {
        if x < -2 || x > 2 { return 0 }
        if abs(x) < 1e-9   { return 1 }
        let px = Double.pi * x
        return 2 * sin(px) * sin(px / 2) / (px * px)
    }

    private func lanczos2Sample(_ px: [Float], w: Int, h: Int, x: Double, y: Double) -> Float? {
        let cx = Int(floor(x)), cy = Int(floor(y))
        var value = 0.0, wsum = 0.0
        for jj in 0..<4 {
            let sy = cy - 1 + jj
            guard sy >= 0, sy < h else { continue }
            let wy = lanczos2Weight(y - Double(sy))
            for ii in 0..<4 {
                let sx = cx - 1 + ii
                guard sx >= 0, sx < w else { continue }
                let weight = lanczos2Weight(x - Double(sx)) * wy
                value += weight * Double(px[sy * w + sx])
                wsum  += weight
            }
        }
        guard wsum > 1e-9 else { return nil }
        return Float(value / wsum)
    }

    // MARK: - Post-warp star-based alignment verification

    private func checkStarAlignment(
        warpedTextures: [MTLTexture],
        referenceIndex refIdx: Int,
        referenceStars: [(x: Double, y: Double)]
    ) -> [(frameIndex: Int, meanResidual: Double, matchedCount: Int, missingCount: Int)] {
        guard !referenceStars.isEmpty else {
            print("[Alignment] No reference stars available — skipping alignment check")
            return (0..<warpedTextures.count).map { (frameIndex: $0, meanResidual: 0, matchedCount: 0, missingCount: 0) }
        }
        print("[Alignment] \(warpedTextures.count) frames, reference=\(refIdx), \(referenceStars.count) reference stars")
        var results: [(frameIndex: Int, meanResidual: Double, matchedCount: Int, missingCount: Int)] = []
        for i in 0..<warpedTextures.count {
            if i == refIdx {
                results.append((frameIndex: i, meanResidual: 0.0, matchedCount: referenceStars.count, missingCount: 0))
                continue
            }
            var totalResidual = 0.0, matched = 0, missing = 0
            for star in referenceStars {
                if let (cx, cy) = starCentroidNear(x: star.x, y: star.y, in: warpedTextures[i]) {
                    let dx = cx - star.x, dy = cy - star.y
                    totalResidual += sqrt(dx*dx + dy*dy)
                    matched += 1
                } else {
                    missing += 1
                }
            }
            let meanRes = matched > 0 ? totalResidual / Double(matched) : 0.0
            let ok = meanRes <= 2.0 && missing <= referenceStars.count / 4
            print(String(format: "[Alignment] frame %2d: mean_residual=%.2fpx  matched=%d/%d  %@",
                         i, meanRes, matched, referenceStars.count, ok ? "ok" : "MISALIGNED"))
            results.append((frameIndex: i, meanResidual: meanRes, matchedCount: matched, missingCount: missing))
        }
        return results
    }

    /// Intensity-weighted centroid within ±radius pixels of (x, y). Returns nil if no signal found.
    private func starCentroidNear(x: Double, y: Double, radius: Int = 8, in texture: MTLTexture) -> (x: Double, y: Double)? {
        let ix = Int(x.rounded()), iy = Int(y.rounded())
        let x0 = max(0, ix - radius), y0 = max(0, iy - radius)
        let x1 = min(texture.width  - 1, ix + radius)
        let y1 = min(texture.height - 1, iy + radius)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        guard w > 0, h > 0 else { return nil }

        var pixels = [Float](repeating: 0, count: w * h)
        texture.getBytes(&pixels,
                         bytesPerRow: w * MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(x0, y0, w, h),
                         mipmapLevel: 0)

        guard let peak = pixels.max(), peak > 0 else { return nil }
        let halfPeak = peak * 0.5
        var sumV = 0.0, sumX = 0.0, sumY = 0.0
        for py in 0..<h {
            for px in 0..<w {
                let v = pixels[py * w + px]
                if v >= halfPeak {
                    let d = Double(v)
                    sumV += d; sumX += d * Double(x0 + px); sumY += d * Double(y0 + py)
                }
            }
        }
        guard sumV > 0 else { return nil }
        return (sumX / sumV, sumY / sumV)
    }

    // MARK: - Normalisation coefficients (CPU, computed from blit samples)

    private func computeNormCoeffs(
        from textures: [MTLTexture],
        method: String,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> [(mulFactor: Float, addOffset: Float)] {
        guard method != "none" else {
            return Array(repeating: (1.0, 0.0), count: textures.count)
        }
        let stats = textures.map { sampleStats(from: $0, device: device, commandQueue: commandQueue) }
        let ref = stats[0]
        return stats.map { s in
            switch method {
            case "additive":
                return (1.0, ref.background - s.background)
            case "multiplicative":
                guard s.scale > 0 else { return (1.0, 0.0) }
                return (ref.scale / s.scale, 0.0)
            case "additive_scaling":
                guard s.scale > 0 else { return (1.0, 0.0) }
                let f = ref.scale / s.scale
                return (f, ref.background - s.background * f)
            case "multiplicative_scaling":
                guard s.std > 0 else { return (1.0, 0.0) }
                let a = ref.std / s.std
                return (a, ref.background - s.background * a)
            default:
                return (1.0, 0.0)
            }
        }
    }

    private func sampleStats(
        from texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> FrameStats {
        let sampleW = min(texture.width,  512)
        let sampleH = min(texture.height, 512)
        let originX = (texture.width  - sampleW) / 2
        let originY = (texture.height - sampleH) / 2
        let bytesPerRow = sampleW * MemoryLayout<Float>.size
        let bufferSize  = bytesPerRow * sampleH

        guard let buf = device.makeBuffer(length: bufferSize, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else {
            return FrameStats(background: 0, scale: 1, std: 1)
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: originX, y: originY, z: 0),
                  sourceSize: MTLSize(width: sampleW, height: sampleH, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bufferSize)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let count = sampleW * sampleH
        let ptr = buf.contents().bindMemory(to: Float.self, capacity: count)
        var pixels = [Float](repeating: 0, count: count)
        for i in 0..<count { pixels[i] = ptr[i] }
        return computeStats(pixels)
    }

    private func computeStats(_ pixels: [Float]) -> FrameStats {
        guard !pixels.isEmpty else { return FrameStats(background: 0, scale: 1, std: 1) }
        let sorted = pixels.sorted()
        let n = sorted.count

        // Sigma-clipped background: iteratively clip at ±2.5σ from the median until convergence.
        // This removes stars and nebulosity so only sky pixels contribute, giving a consistent
        // background estimate even when different warped frames capture different amounts of
        // extended emission in their center sample region.
        var sky = sorted
        for _ in 0..<10 {
            let m = sky.count
            guard m > 1 else { break }
            let median: Float = m.isMultiple(of: 2) ? (sky[m/2-1] + sky[m/2])/2 : sky[m/2]
            var variance: Float = 0
            for v in sky { let d = v - median; variance += d * d }
            let sigma = sqrt(variance / Float(m))
            guard sigma > 1e-7 else { break }
            let lo = median - 2.5 * sigma
            let hi = median + 2.5 * sigma
            let clipped = sky.filter { $0 >= lo && $0 <= hi }
            if clipped.count == sky.count { break }
            sky = clipped.isEmpty ? sky : clipped
        }
        let sm = sky.count
        let background: Float = sm.isMultiple(of: 2) ? (sky[sm/2-1] + sky[sm/2])/2 : sky[sm/2]

        let q25  = sorted[n / 4]
        let q75  = sorted[min(n - 1, 3 * n / 4)]
        let std  = max(1e-7, (q75 - q25) / 1.349)
        let scaleStart = n / 2
        let scaleEnd   = min(n - 1, n * 95 / 100)
        let scale = scaleStart <= scaleEnd ? sorted[(scaleStart + scaleEnd) / 2] : sorted[n / 2]
        return FrameStats(background: background, scale: max(1e-7, scale), std: std)
    }

    // MARK: - GPU stacking

    private func stackOnGPU(
        frames: [MTLTexture],
        normCoeffs: [(mulFactor: Float, addOffset: Float)],
        method: String, rejection: String, rejLow: Float, rejHigh: Float,
        width: Int, height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let nFrames = frames.count

        guard let library = AstrophotoKit.makeShaderLibrary(device: device),
              let fn = library.makeFunction(name: "stack_frames"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else {
            Logger.processor.warning("FrameStacking: GPU stack shader unavailable, falling back to CPU")
            return try cpuStackFallback(
                frames: frames, normCoeffs: normCoeffs,
                method: method, rejection: rejection, rejLow: rejLow, rejHigh: rejHigh,
                width: width, height: height, device: device, commandQueue: commandQueue
            )
        }

        // Build texture2d_array by blitting each warped frame into a slice
        let arrayDesc = MTLTextureDescriptor()
        arrayDesc.textureType  = .type2DArray
        arrayDesc.pixelFormat  = .r32Float
        arrayDesc.width        = width
        arrayDesc.height       = height
        arrayDesc.arrayLength  = nFrames
        arrayDesc.usage        = [.shaderRead]
        guard let arrayTex = device.makeTexture(descriptor: arrayDesc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create frame texture array")
        }

        guard let blitCmd = commandQueue.makeCommandBuffer(),
              let blitEnc = blitCmd.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.executionFailed("Failed to create blit encoder for texture array")
        }
        for (i, tex) in frames.enumerated() {
            blitEnc.copy(
                from: tex, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: arrayTex, destinationSlice: i, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        blitEnc.endEncoding()
        blitCmd.commit()
        blitCmd.waitUntilCompleted()

        // Output texture
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let outTex = device.makeTexture(descriptor: outDesc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create stacked output texture")
        }

        // StackParams buffer
        var stackParams = StackParams(
            nFrames:   UInt32(nFrames),
            stackMode: UInt32(stackModeIndex(method)),
            rejMode:   UInt32(rejModeIndex(rejection)),
            rejLow:    rejLow,
            rejHigh:   rejHigh
        )
        guard let paramsBuf = device.makeBuffer(
            bytes: &stackParams,
            length: MemoryLayout<StackParams>.size,
            options: .storageModeShared
        ) else {
            throw ProcessorExecutionError.executionFailed("Failed to create stack params buffer")
        }

        // FrameNorm buffer
        var normData = normCoeffs.map { FrameNorm(mulFactor: $0.mulFactor, addOffset: $0.addOffset) }
        guard let normBuf = device.makeBuffer(
            bytes: &normData,
            length: normData.count * MemoryLayout<FrameNorm>.size,
            options: .storageModeShared
        ) else {
            throw ProcessorExecutionError.executionFailed("Failed to create norm params buffer")
        }

        // Dispatch
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            throw ProcessorExecutionError.executionFailed("Failed to create stack compute encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(arrayTex, index: 0)
        enc.setTexture(outTex,   index: 1)
        enc.setBuffer(paramsBuf, offset: 0, index: 0)
        enc.setBuffer(normBuf,   offset: 0, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let gc = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(gc, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return outTex
    }

    private func stackModeIndex(_ method: String) -> Int {
        switch method {
        case "average":   return 0
        case "sum":       return 1
        case "median":    return 2
        case "max_pixel": return 3
        case "min_pixel": return 4
        default:          return 0
        }
    }

    private func rejModeIndex(_ rejection: String) -> Int {
        switch rejection {
        case "none":       return 0
        case "sigma_clip": return 1
        case "winsorized": return 2
        default:           return 1
        }
    }

    // MARK: - CPU fallback (used when GPU stack shader is unavailable)

    private func cpuStackFallback(
        frames: [MTLTexture],
        normCoeffs: [(mulFactor: Float, addOffset: Float)],
        method: String, rejection: String, rejLow: Float, rejHigh: Float,
        width: Int, height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        var pixelArrays = frames.map { readPixels(from: $0, width: width, height: height) }
        // Apply normalisation coefficients
        pixelArrays = pixelArrays.enumerated().map { (i, frame) in
            let m = normCoeffs[i].mulFactor, a = normCoeffs[i].addOffset
            guard m != 1.0 || a != 0.0 else { return frame }
            return frame.map { $0 * m + a }
        }
        let stacked = cpuStack(pixelArrays, method: method, rejection: rejection,
                               rejLow: rejLow, rejHigh: rejHigh, nPixels: width * height)
        return try pixelsToTexture(stacked, width: width, height: height, device: device)
    }

    private func cpuStack(
        _ frames: [[Float]],
        method: String, rejection: String, rejLow: Float, rejHigh: Float,
        nPixels: Int
    ) -> [Float] {
        let nFrames = frames.count
        var result = [Float](repeating: 0, count: nPixels)
        for p in 0..<nPixels {
            // Skip sentinel values (-1) from out-of-bounds warp pixels
            var vals = frames.map { $0[p] }.filter { $0 >= 0 }
            guard !vals.isEmpty else { continue }
            if rejection != "none" && nFrames > 2 {
                vals = applyRejection(vals, low: rejLow, high: rejHigh, method: rejection)
            }
            guard !vals.isEmpty else { continue }
            result[p] = switch method {
            case "sum":       vals.reduce(0, +)
            case "median":    cpuMedian(vals)
            case "max_pixel": vals.max()!
            case "min_pixel": vals.min()!
            default:          vals.reduce(0, +) / Float(vals.count)
            }
        }
        return result
    }

    private func applyRejection(_ vals: [Float], low: Float, high: Float, method: String) -> [Float] {
        guard vals.count > 2 else { return vals }
        switch method {
        case "sigma_clip": return sigmaClip(vals, low: low, high: high)
        case "winsorized": return winsorizedSigmaClip(vals, low: low, high: high, iterations: 3)
        default:           return sigmaClip(vals, low: low, high: high)
        }
    }

    private func sigmaClip(_ vals: [Float], low: Float, high: Float) -> [Float] {
        var working = vals.sorted()
        for _ in 0..<3 {
            let m = working.count
            guard m > 2 else { break }
            let med: Float = m.isMultiple(of: 2)
                ? (working[m/2-1] + working[m/2]) / 2 : working[m/2]
            let devs = working.map { abs($0 - med) }.sorted()
            let mad = m.isMultiple(of: 2)
                ? (devs[m/2-1] + devs[m/2]) / 2 : devs[m/2]
            let sigma = mad / 0.6745
            guard sigma > 1e-9 else { break }
            let lo = med - low  * sigma
            let hi = med + high * sigma
            let clipped = working.filter { $0 >= lo && $0 <= hi }
            if clipped.count == working.count { break }
            working = clipped.isEmpty ? working : clipped
        }
        return working
    }

    private func winsorizedSigmaClip(_ vals: [Float], low: Float, high: Float, iterations: Int) -> [Float] {
        var working = vals
        for _ in 0..<iterations {
            let mean = working.reduce(0, +) / Float(working.count)
            let variance = working.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(working.count)
            let sigma = sqrt(variance)
            guard sigma > 0 else { break }
            let lo = mean - low  * sigma
            let hi = mean + high * sigma
            let winsorized = working.map { min(hi, max(lo, $0)) }
            let wm = winsorized.reduce(0, +) / Float(winsorized.count)
            let ws = sqrt(winsorized.map { ($0 - wm) * ($0 - wm) }.reduce(0, +) / Float(winsorized.count))
            guard ws > 0 else { break }
            let filtered = working.filter { $0 >= wm - low * ws && $0 <= wm + high * ws }
            if filtered.count == working.count { break }
            working = filtered.isEmpty ? working : filtered
        }
        return working
    }

    private func cpuMedian(_ vals: [Float]) -> Float {
        let s = vals.sorted()
        let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m-1] + s[m]) / 2 : s[m]
    }

    // MARK: - Texture helpers

    private func readPixels(from texture: MTLTexture, width: Int, height: Int) -> [Float] {
        var px = [Float](repeating: 0, count: width * height)
        texture.getBytes(&px,
                         bytesPerRow: width * MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        return px
    }

    private func pixelsToTexture(_ pixels: [Float], width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create texture from pixel array")
        }
        pixels.withUnsafeBytes { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float>.size
            )
        }
        return tex
    }
}
