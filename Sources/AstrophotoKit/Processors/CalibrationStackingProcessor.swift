import Foundation
import Metal
import os

/// Stacks calibration frames (bias, dark, flat, darkflat) into a master frame using
/// pixel-wise median or mean combination. No spatial registration is applied —
/// calibration frames are assumed to be already aligned (they have no stars to register).
///
/// A single-frame input is passed through unchanged, so this processor also acts as
/// a pass-through when the user supplies a pre-made master frame.
///
/// **Input**
/// - `input_frames` (FrameSet) — calibration frames to combine.
///
/// **Parameters**
/// | Name    | Type   | Default | Description                          |
/// |---------|--------|---------|--------------------------------------|
/// | method  | String | median  | Combine method: `median` or `mean`.  |
///
/// **Output**
/// - `master_frame` (Frame) — combined master calibration frame.
public struct CalibrationStackingProcessor: Processor {

    public var id: String { "stack_calibration_frames" }
    public init() {}

    // Mirror of the StackParams struct in StackShader.metal / FrameStackingProcessor.
    // Layout must stay in sync with the Metal shader.
    private struct StackParams {
        var nFrames:   UInt32
        var stackMode: UInt32  // 0=average, 2=median
        var rejMode:   UInt32  // 0=none
        var rejLow:    Float
        var rejHigh:   Float
    }

    private struct FrameNorm {
        var mulFactor: Float
        var addOffset: Float
    }

    private let stackMaxFrames = 128

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

        let method = parameters["method"]?.stringValue ?? "median"
        let nFrames = frameSet.frames.count

        Logger.processor.info(
            "CalibrationStackingProcessor: \(nFrames) frame(s), method=\(method)"
        )

        // Fast path: a single frame is already a master — pass the texture through.
        if nFrames == 1 {
            guard let tex = frameSet.frames[0].texture else {
                throw ProcessorExecutionError.executionFailed("Input frame has no texture")
            }
            try ProcessorHelpers.updateOutputFrame(
                outputs: &outputs, outputName: "master_frame", texture: tex
            )
            return
        }

        guard nFrames <= stackMaxFrames else {
            throw ProcessorExecutionError.executionFailed(
                "CalibrationStackingProcessor: \(nFrames) frames exceeds the GPU kernel limit " +
                "of \(stackMaxFrames). Split your input into smaller batches."
            )
        }

        guard let refTex = frameSet.frames[0].texture else {
            throw ProcessorExecutionError.executionFailed("First frame has no texture")
        }
        let width  = refTex.width
        let height = refTex.height

        let outTex = try stackOnGPU(
            frames: frameSet.frames,
            method: method,
            width: width, height: height,
            device: device, commandQueue: commandQueue
        )

        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs, outputName: "master_frame", texture: outTex
        )
        Logger.processor.info(
            "CalibrationStackingProcessor: stacked \(nFrames) frames → master"
        )
    }

    // MARK: - GPU stacking (reuses the shared `stack_frames` Metal kernel)

    private func stackOnGPU(
        frames: [Frame],
        method: String,
        width: Int, height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        guard let library = AstrophotoKit.makeShaderLibrary(device: device),
              let fn       = library.makeFunction(name: "stack_frames"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else {
            Logger.processor.warning(
                "CalibrationStackingProcessor: GPU stack shader unavailable, using CPU fallback"
            )
            return try cpuStack(frames: frames, method: method,
                                width: width, height: height, device: device)
        }

        // Build a texture2d_array from all frames.
        let arrayDesc = MTLTextureDescriptor()
        arrayDesc.textureType  = .type2DArray
        arrayDesc.pixelFormat  = .r32Float
        arrayDesc.width        = width
        arrayDesc.height       = height
        arrayDesc.arrayLength  = frames.count
        arrayDesc.usage        = [.shaderRead]
        guard let arrayTex = device.makeTexture(descriptor: arrayDesc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create frame texture array")
        }

        guard let blitCmd = commandQueue.makeCommandBuffer(),
              let blitEnc = blitCmd.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.executionFailed("Failed to create blit encoder")
        }
        for (i, frame) in frames.enumerated() {
            guard let src = frame.texture else { continue }
            blitEnc.copy(
                from: src, sourceSlice: 0, sourceLevel: 0,
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
            throw ProcessorExecutionError.executionFailed("Failed to create output texture")
        }

        var params = StackParams(
            nFrames:   UInt32(frames.count),
            stackMode: method == "mean" ? 0 : 2,  // 0=average, 2=median
            rejMode:   0,                           // no rejection for calibration stacking
            rejLow:    3.0,
            rejHigh:   3.0
        )
        guard let paramsBuf = device.makeBuffer(
            bytes: &params, length: MemoryLayout<StackParams>.size, options: .storageModeShared
        ) else {
            throw ProcessorExecutionError.executionFailed("Failed to create stack params buffer")
        }

        // Identity normalization (no per-frame scaling needed for calibration frames).
        var normData = [FrameNorm](repeating: FrameNorm(mulFactor: 1.0, addOffset: 0.0),
                                   count: frames.count)
        guard let normBuf = device.makeBuffer(
            bytes: &normData,
            length: normData.count * MemoryLayout<FrameNorm>.size,
            options: .storageModeShared
        ) else {
            throw ProcessorExecutionError.executionFailed("Failed to create norm params buffer")
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc    = cmdBuf.makeComputeCommandEncoder() else {
            throw ProcessorExecutionError.executionFailed("Failed to create compute encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(arrayTex, index: 0)
        enc.setTexture(outTex,   index: 1)
        enc.setBuffer(paramsBuf, offset: 0, index: 0)
        enc.setBuffer(normBuf,   offset: 0, index: 1)
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

    // MARK: - CPU fallback

    private func cpuStack(
        frames: [Frame], method: String,
        width: Int, height: Int, device: MTLDevice
    ) throws -> MTLTexture {
        let nPx = width * height
        var pixelArrays: [[Float]] = []
        for frame in frames {
            guard let tex = frame.texture else { continue }
            var px = [Float](repeating: 0, count: nPx)
            tex.getBytes(&px,
                         bytesPerRow: width * MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
            pixelArrays.append(px)
        }
        guard !pixelArrays.isEmpty else {
            throw ProcessorExecutionError.executionFailed("No frames with textures to stack")
        }

        var result = [Float](repeating: 0, count: nPx)
        for p in 0..<nPx {
            var vals = pixelArrays.map { $0[p] }
            if method == "mean" {
                result[p] = vals.reduce(0, +) / Float(vals.count)
            } else {
                vals.sort()
                let n = vals.count
                result[p] = n.isMultiple(of: 2) ? (vals[n/2-1] + vals[n/2]) / 2 : vals[n/2]
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw ProcessorExecutionError.executionFailed("Failed to create output texture")
        }
        result.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: $0.baseAddress!,
                        bytesPerRow: width * MemoryLayout<Float>.size)
        }
        return tex
    }
}
