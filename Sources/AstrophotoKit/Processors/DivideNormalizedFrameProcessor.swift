import Foundation
import Metal
import os

/// Applies flat-field correction by dividing an input frame by a normalized master flat.
///
/// The master flat is normalized to its mean pixel value before division, making the
/// correction independent of the flat's overall brightness level:
///   result = input / (flat / mean(flat)) = input × mean(flat) / flat
///
/// Pixels where the flat is zero (or near zero) are preserved unchanged to avoid
/// division-by-zero artefacts.
///
/// The processor warns when the input and flat frame have different filters or when the
/// flat has a timestamp more than 24 hours from the input, as flats should match the
/// filter used for the lights and be taken close in time.
///
/// **Inputs**
/// - `input_frame`   (Frame) — frame to correct (e.g. dark-subtracted light frame).
/// - `divisor_frame` (Frame) — master flat frame used as the divisor.
///
/// **Output**
/// - `calibrated_frame` (Frame) — flat-field-corrected result.
public struct DivideNormalizedFrameProcessor: Processor {

    public var id: String { "divide_normalized_frame" }
    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let inputFrame   = inputs["input_frame"]   as? Frame,
              let inputTexture = inputFrame.texture else {
            throw ProcessorExecutionError.missingRequiredInput("input_frame")
        }
        guard let divisorFrame   = inputs["divisor_frame"] as? Frame,
              let divisorTexture = divisorFrame.texture else {
            throw ProcessorExecutionError.missingRequiredInput("divisor_frame")
        }

        let w = inputTexture.width, h = inputTexture.height
        guard divisorTexture.width == w, divisorTexture.height == h else {
            throw ProcessorExecutionError.executionFailed(
                "divide_normalized_frame: dimension mismatch — " +
                "input \(w)×\(h), divisor \(divisorTexture.width)×\(divisorTexture.height)"
            )
        }

        try logWarnings(input: inputFrame, divisor: divisorFrame)

        let flatMean = computeMean(
            texture: divisorTexture, width: w, height: h,
            device: device, commandQueue: commandQueue
        )
        guard flatMean > 1e-9 else {
            throw ProcessorExecutionError.executionFailed(
                "divide_normalized_frame: master flat has near-zero mean — " +
                "cannot normalize for flat-field correction"
            )
        }

        Logger.processor.debug(
            "DivideNormalizedFrameProcessor: flat mean=\(String(format: "%.4f", flatMean))"
        )

        let outTex = try divide(
            input: inputTexture, divisor: divisorTexture,
            divisorMean: Float(flatMean),
            width: w, height: h,
            device: device, commandQueue: commandQueue
        )
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs, outputName: "calibrated_frame", texture: outTex
        )
    }

    // MARK: - Validation

    private func logWarnings(input: Frame, divisor: Frame) throws {
        // Gain mismatch: flat must be taken at the same gain as the light.
        if let g1 = input.gain, let g2 = divisor.gain {
            if abs(g1 - g2) > 0.5 {
                throw ProcessorExecutionError.executionFailed(
                    "divide_normalized_frame: gain mismatch — input gain \(Int(g1)) vs flat gain \(Int(g2)). " +
                    "Flat frames must be taken at the same gain setting as the light frames."
                )
            }
        }

        // Offset mismatch: warn if camera pedestal differs.
        if let o1 = input.offset, let o2 = divisor.offset, abs(o1 - o2) > 5 {
            let msg = "divide_normalized_frame: offset mismatch — input offset \(Int(o1)) vs flat offset \(Int(o2)). Calibration quality may be reduced."
            Logger.processor.warning("\(msg, privacy: .public)")
        }

        // Filter mismatch: flat must use the same filter as the light.
        let inFilter  = input.filterName  ?? input.filter.rawValue
        let divFilter = divisor.filterName ?? divisor.filter.rawValue
        if input.filter != .none && input.filter != .unknown
            && divisor.filter != .none && divisor.filter != .unknown
            && input.filter != divisor.filter {
            let msg = "divide_normalized_frame: filter mismatch — light '\(inFilter)' vs flat '\(divFilter)'. Flat frames must be taken through the same filter as the light frames."
            Logger.processor.warning("\(msg, privacy: .public)")
        }

        // Timestamp: flats should be close in time to lights.
        if let t1 = input.timestamp, let t2 = divisor.timestamp {
            let hours = abs(t1.timeIntervalSince(t2)) / 3600
            if hours > 24 {
                let msg = "divide_normalized_frame: flat timestamp is \(String(format: "%.1f", hours))h from light frame. Flats should ideally be taken the same night as lights."
                Logger.processor.warning("\(msg, privacy: .public)")
            }
        }
    }

    // MARK: - Mean computation (CPU, sampled from GPU memory)

    private func computeMean(
        texture: MTLTexture, width: Int, height: Int,
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) -> Double {
        // Sample every 4th pixel for speed on large sensors.
        let step    = 4
        let sampleW = max(1, width  / step)
        let sampleH = max(1, height / step)
        let bpr     = sampleW * MemoryLayout<Float>.size
        guard let buf = device.makeBuffer(length: bpr * sampleH, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit   = cmdBuf.makeBlitCommandEncoder() else {
            return 0
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: sampleW, height: sampleH, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * sampleH)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let count = sampleW * sampleH
        let ptr   = buf.contents().bindMemory(to: Float.self, capacity: count)
        var sum: Double = 0
        for i in 0..<count { sum += Double(ptr[i]) }
        return count > 0 ? sum / Double(count) : 0
    }

    // MARK: - GPU/CPU division

    private func divide(
        input: MTLTexture, divisor: MTLTexture,
        divisorMean: Float,
        width: Int, height: Int,
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let outTex = device.makeTexture(descriptor: desc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create output texture")
        }

        // GPU path
        if let library  = AstrophotoKit.makeShaderLibrary(device: device),
           let fn        = library.makeFunction(name: "divide_normalized_frame"),
           let pipeline  = try? device.makeComputePipelineState(function: fn) {

            var mean = divisorMean
            guard let meanBuf = device.makeBuffer(
                bytes: &mean, length: MemoryLayout<Float>.size, options: .storageModeShared
            ) else {
                throw ProcessorExecutionError.executionFailed("Failed to create mean buffer")
            }

            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let enc    = cmdBuf.makeComputeCommandEncoder() else {
                throw ProcessorExecutionError.executionFailed("Failed to create compute encoder")
            }
            enc.setComputePipelineState(pipeline)
            enc.setTexture(input,   index: 0)
            enc.setTexture(divisor, index: 1)
            enc.setTexture(outTex,  index: 2)
            enc.setBuffer(meanBuf, offset: 0, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let gc = MTLSize(
                width:  (width  + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )
            enc.dispatchThreadgroups(gc, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            return outTex
        }

        // CPU fallback
        Logger.processor.warning(
            "DivideNormalizedFrameProcessor: GPU shader unavailable, using CPU fallback"
        )
        let nPx    = width * height
        let region = MTLRegionMake2D(0, 0, width, height)
        let bpr    = width * MemoryLayout<Float>.size
        var inPx   = [Float](repeating: 0, count: nPx)
        var divPx  = [Float](repeating: 0, count: nPx)
        input.getBytes(&inPx,  bytesPerRow: bpr, from: region, mipmapLevel: 0)
        divisor.getBytes(&divPx, bytesPerRow: bpr, from: region, mipmapLevel: 0)

        let outPx = zip(inPx, divPx).map { a, d -> Float in
            d > 1e-9 ? a * divisorMean / d : a
        }
        outPx.withUnsafeBytes {
            outTex.replace(region: region, mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: bpr)
        }
        return outTex
    }
}
