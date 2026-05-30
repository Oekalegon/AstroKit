import Foundation
import Metal
import os

/// Subtracts one calibration frame from another pixel-by-pixel.
///
/// Typical uses:
/// - Subtract master bias from dark frames before stacking.
/// - Subtract master dark flat from flat frames before stacking.
///
/// The processor logs a warning when the input and subtracted frames have mismatched
/// sensor temperatures (>5 °C delta) or mismatched exposure times (>5 % relative delta),
/// as these conditions degrade calibration quality.
///
/// **Inputs**
/// - `input_frame`    (Frame) — frame to subtract from.
/// - `subtract_frame` (Frame) — frame to subtract (e.g. master bias or master dark flat).
///
/// **Parameters**
/// | Name          | Type | Default | Description                                       |
/// |---------------|------|---------|---------------------------------------------------|
/// | clip_to_zero  | Bool | true    | Clamp negative results to 0 after subtraction.    |
///
/// **Output**
/// - `calibrated_frame` (Frame) — result of input − subtract.
public struct SubtractFramesProcessor: Processor {

    public var id: String { "subtract_frames" }
    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let inputFrame   = inputs["input_frame"]    as? Frame,
              let inputTexture = inputFrame.texture else {
            throw ProcessorExecutionError.missingRequiredInput("input_frame")
        }
        guard let subtractFrame   = inputs["subtract_frame"] as? Frame,
              let subtractTexture = subtractFrame.texture else {
            throw ProcessorExecutionError.missingRequiredInput("subtract_frame")
        }

        let clipToZero = parameters["clip_to_zero"]?.stringValue != "false"

        let w = inputTexture.width, h = inputTexture.height
        guard subtractTexture.width == w, subtractTexture.height == h else {
            throw ProcessorExecutionError.executionFailed(
                "subtract_frames: dimension mismatch — " +
                "input \(w)×\(h), subtract \(subtractTexture.width)×\(subtractTexture.height)"
            )
        }

        try validateAndWarn(input: inputFrame, subtract: subtractFrame)

        let outTex = try subtract(
            input: inputTexture, subtract: subtractTexture,
            clipToZero: clipToZero,
            width: w, height: h,
            device: device, commandQueue: commandQueue
        )
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs, outputName: "calibrated_frame", texture: outTex
        )
    }

    // MARK: - Validation

    private func validateAndWarn(input: Frame, subtract: Frame) throws {
        // Gain mismatch: calibration frames must be taken at the same gain setting.
        if let g1 = input.gain, let g2 = subtract.gain {
            if abs(g1 - g2) > 0.5 {
                throw ProcessorExecutionError.executionFailed(
                    "subtract_frames: gain mismatch — input gain \(Int(g1)) vs subtract gain \(Int(g2)). " +
                    "Calibration frames must be taken at the same gain setting as the input frame."
                )
            }
        }

        // Camera model mismatch: warn if frames are from different instruments.
        if let c1 = input.instrumentName, let c2 = subtract.instrumentName, c1 != c2 {
            let msg = "subtract_frames: camera mismatch — input '\(c1)' vs calibration '\(c2)'. Calibration frames should be from the same camera model."
            Logger.processor.warning("\(msg, privacy: .public)")
        }

        // Offset mismatch: warn if camera pedestal differs.
        if let o1 = input.offset, let o2 = subtract.offset, abs(o1 - o2) > 5 {
            let msg = "subtract_frames: offset mismatch — input offset \(Int(o1)) vs subtract offset \(Int(o2)). Calibration quality may be reduced."
            Logger.processor.warning("\(msg, privacy: .public)")
        }

        // Temperature check for dark subtraction.
        if let t1 = input.ccdTemperature, let t2 = subtract.ccdTemperature {
            let delta = abs(t1 - t2)
            if delta > 5.0 {
                let msg = "subtract_frames: temperature mismatch — input \(String(format: "%.1f", t1))°C vs subtract \(String(format: "%.1f", t2))°C (Δ=\(String(format: "%.1f", delta))°C). Calibration quality may be reduced."
                Logger.processor.warning("\(msg, privacy: .public)")
            }
        } else if input.ccdTemperature == nil && subtract.ccdTemperature == nil {
            // Uncooled camera: no temperature metadata. Check observation date proximity instead.
            if let t1 = input.timestamp, let t2 = subtract.timestamp {
                let hours = abs(t1.timeIntervalSince(t2)) / 3600
                if hours > 12 {
                    let msg = String(format:
                        "subtract_frames: no CCD temperature metadata (uncooled camera?). " +
                        "Input and calibration frame timestamps differ by %.1f h — " +
                        "for uncooled cameras, calibration frames should be from the same observing session.",
                        hours)
                    Logger.processor.warning("\(msg, privacy: .public)")
                }
            }
        }

        // Exposure time mismatch (dark vs light).
        if let e1 = input.exposureTime, let e2 = subtract.exposureTime, e1 > 0, e2 > 0 {
            let relDelta = abs(e1 - e2) / max(e1, e2)
            if relDelta > 0.05 {
                let msg = "subtract_frames: exposure time mismatch — input \(String(format: "%.3f", e1))s vs subtract \(String(format: "%.3f", e2))s. Dark frames must match light frame exposure time."
                Logger.processor.warning("\(msg, privacy: .public)")
            }
        }
    }

    // MARK: - GPU/CPU subtraction

    private func subtract(
        input: MTLTexture, subtract: MTLTexture,
        clipToZero: Bool,
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
           let fn        = library.makeFunction(name: "subtract_frames"),
           let pipeline  = try? device.makeComputePipelineState(function: fn) {

            var clip = clipToZero
            guard let clipBuf = device.makeBuffer(
                bytes: &clip, length: MemoryLayout<Bool>.size, options: .storageModeShared
            ) else {
                throw ProcessorExecutionError.executionFailed("Failed to create clip buffer")
            }

            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let enc    = cmdBuf.makeComputeCommandEncoder() else {
                throw ProcessorExecutionError.executionFailed("Failed to create compute encoder")
            }
            enc.setComputePipelineState(pipeline)
            enc.setTexture(input,    index: 0)
            enc.setTexture(subtract, index: 1)
            enc.setTexture(outTex,   index: 2)
            enc.setBuffer(clipBuf, offset: 0, index: 0)
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
            "SubtractFramesProcessor: GPU shader unavailable, using CPU fallback"
        )
        let nPx = width * height
        var inPx  = [Float](repeating: 0, count: nPx)
        var subPx = [Float](repeating: 0, count: nPx)
        let region = MTLRegionMake2D(0, 0, width, height)
        let bpr    = width * MemoryLayout<Float>.size
        input.getBytes(&inPx,  bytesPerRow: bpr, from: region, mipmapLevel: 0)
        subtract.getBytes(&subPx, bytesPerRow: bpr, from: region, mipmapLevel: 0)

        let outPx = zip(inPx, subPx).map { a, b -> Float in
            let v = a - b; return clipToZero ? max(0, v) : v
        }
        outPx.withUnsafeBytes {
            outTex.replace(region: region, mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: bpr)
        }
        return outTex
    }
}
