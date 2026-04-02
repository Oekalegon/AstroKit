import Foundation
import Metal
import TabularData
import os

/// Processor that draws detected Hough circles (outer and inner) onto a grayscale image.
///
/// Takes the `donuts` table from `HoughCircleProcessor` and renders:
/// - Outer circles in green with a small crosshair at the centre
/// - Inner circles (secondary mirror shadow) in red without a crosshair
///
/// **Inputs**
/// - `input_frame` (Frame)     — grayscale source image
/// - `donuts`      (TableData) — output from `HoughCircleProcessor`
///
/// **Parameters**
/// - `line_width`       Double (default 2.0) — stroke width in pixels
/// - `crosshair_ratio`  Double (default 0.3) — crosshair arm length as fraction of outer radius
///
/// **Output**
/// - `annotated_frame` (Frame, rgba32Float)
public struct HoughCircleOverlayProcessor: Processor {

    public var id: String { "hough_circle_overlay" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        guard let donutTable = inputs["donuts"] as? TableData,
              let df = donutTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("donuts")
        }

        let lineWidth      = Float(parameters["line_width"]?.doubleValue      ?? 2.0)
        let crosshairRatio = Float(parameters["crosshair_ratio"]?.doubleValue ?? 0.3)

        // Build CircleDrawData arrays (8 floats per entry: cx, cy, radius, lineWidth, r, g, b, crosshairSize)
        let (outerCircles, innerCircles) = buildCircleData(
            from: df,
            lineWidth: lineWidth,
            crosshairRatio: crosshairRatio
        )

        let logMsg = "HoughCircleOverlayProcessor: \(outerCircles.count / 8) donuts"
        Logger.processor.info("\(logMsg)")

        // Create RGBA output texture
        let descriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: .rgba32Float,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(descriptor: descriptor, device: device)

        // Copy grayscale → RGBA
        try copyGrayscaleToRGBA(
            inputTexture: inputTexture,
            outputTexture: outputTexture,
            device: device,
            commandQueue: commandQueue
        )

        // Draw outer circles (green, with crosshairs)
        if !outerCircles.isEmpty {
            try drawCircles(
                on: outputTexture,
                circleData: outerCircles,
                device: device,
                commandQueue: commandQueue
            )
        }

        // Draw inner circles (red, no crosshairs)
        if !innerCircles.isEmpty {
            try drawCircles(
                on: outputTexture,
                circleData: innerCircles,
                device: device,
                commandQueue: commandQueue
            )
        }

        if var outputFrame = outputs["annotated_frame"] as? Frame {
            outputFrame.texture = outputTexture
            outputs["annotated_frame"] = outputFrame
        }
    }

    // MARK: - Data Building

    /// Returns (outerCircleData, innerCircleData) as flat Float arrays.
    /// Each entry is 8 floats: cx, cy, radius, lineWidth, colorR, colorG, colorB, crosshairSize.
    private func buildCircleData(
        from df: DataFrame,
        lineWidth: Float,
        crosshairRatio: Float
    ) -> ([Float], [Float]) {
        guard let ocxCol = df["outer_cx"] as? AnyColumn,
              let ocyCol = df["outer_cy"] as? AnyColumn,
              let orCol  = df["outer_r"]  as? AnyColumn,
              let icxCol = df["inner_cx"] as? AnyColumn,
              let icyCol = df["inner_cy"] as? AnyColumn,
              let irCol  = df["inner_r"]  as? AnyColumn else {
            return ([], [])
        }

        var outer: [Float] = []
        var inner: [Float] = []

        for i in 0..<df.rows.count {
            guard let ocx = ocxCol[i] as? Double,
                  let ocy = ocyCol[i] as? Double,
                  let or_ = orCol[i]  as? Double else { continue }

            let crosshair = Float(or_) * crosshairRatio
            // Outer: green, with crosshair
            outer.append(contentsOf: [
                Float(ocx), Float(ocy), Float(or_), lineWidth,
                0.0, 1.0, 0.0,   // green
                crosshair
            ])

            // Inner: red, no crosshair
            if let icx = icxCol[i] as? Double,
               let icy = icyCol[i] as? Double,
               let ir_ = irCol[i]  as? Double {
                inner.append(contentsOf: [
                    Float(icx), Float(icy), Float(ir_), lineWidth,
                    1.0, 0.0, 0.0,   // red
                    0.0              // no crosshair
                ])
            }
        }

        return (outer, inner)
    }

    // MARK: - Metal Helpers

    private func copyGrayscaleToRGBA(
        inputTexture: MTLTexture,
        outputTexture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "copy_grayscale_to_rgba") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load copy_grayscale_to_rgba shader")
        }

        let pipelineState = try ProcessorHelpers.createComputePipelineState(function: function, device: device)
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder       = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inputTexture,  index: 0)
        encoder.setTexture(outputTexture, index: 1)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
    }

    /// Dispatches the `draw_circles` kernel with the given flat float array.
    /// circleData must be a multiple of 8 floats (one CircleDrawData per entry).
    private func drawCircles(
        on texture: MTLTexture,
        circleData: [Float],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "draw_circles") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load draw_circles shader")
        }

        let pipelineState = try ProcessorHelpers.createComputePipelineState(function: function, device: device)

        let circlesBuffer = try ProcessorHelpers.createBuffer(data: circleData, device: device)

        var numCircles = Int32(circleData.count / 8)
        let numCirclesBuffer = try ProcessorHelpers.createBuffer(from: &numCircles, device: device)

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder       = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)          // read_write in-place
        encoder.setBuffer(circlesBuffer,    offset: 0, index: 0)
        encoder.setBuffer(numCirclesBuffer, offset: 0, index: 1)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: texture)
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
    }
}
