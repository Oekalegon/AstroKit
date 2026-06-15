import Foundation
import Metal
import os
import TabularData

/// Structure representing a star ellipse for overlay drawing
private struct StarEllipse {
    let centroidX: Float
    let centroidY: Float
    let majorAxis: Float
    let minorAxis: Float
    let rotationAngle: Float // in radians
}

/// Structure representing a quad line (4 points forming a quadrilateral)
private struct QuadLine {
    let x1: Float
    let y1: Float
    let x2: Float
    let y2: Float
    let x3: Float
    let y3: Float
    let x4: Float
    let y4: Float
}

/// Processor that draws ellipses and quads around detected stars on an image
public struct StarDetectionOverlayProcessor: Processor {
    public var id: String { "star_detection_overlay" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Extract input frame
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        // Extract pixel_coordinates table
        guard let pixelCoordinatesTable = inputs["pixel_coordinates"] as? TableData,
              let pixelCoordinatesDF = pixelCoordinatesTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("pixel_coordinates")
        }

        // Extract ellipses from pixel_coordinates table
        let ellipses = try extractEllipses(from: pixelCoordinatesDF)

        // Extract quads (optional)
        var quads: [QuadLine] = []
        if let quadsTable = inputs["quads"] as? TableData,
           let quadsDF = quadsTable.dataFrame {
            quads = try extractQuads(from: quadsDF)
        }

        // Extract draw flags
        let drawEllipses = extractBoolParameter(parameters, name: "draw_ellipses", defaultValue: true)
        let drawQuads = extractBoolParameter(parameters, name: "draw_quads", defaultValue: true)

        // Extract color and width parameters
        let ellipseColorR = extractDoubleParameter(parameters, name: "ellipse_color_r", defaultValue: 1.0)
        let ellipseColorG = extractDoubleParameter(parameters, name: "ellipse_color_g", defaultValue: 0.0)
        let ellipseColorB = extractDoubleParameter(parameters, name: "ellipse_color_b", defaultValue: 0.0)
        let ellipseColor = SIMD3<Float>(Float(ellipseColorR), Float(ellipseColorG), Float(ellipseColorB))
        let ellipseWidth = Float(extractDoubleParameter(parameters, name: "ellipse_width", defaultValue: 1.0))

        let quadColorR = extractDoubleParameter(parameters, name: "quad_color_r", defaultValue: 0.0)
        let quadColorG = extractDoubleParameter(parameters, name: "quad_color_g", defaultValue: 1.0)
        let quadColorB = extractDoubleParameter(parameters, name: "quad_color_b", defaultValue: 0.0)
        let quadColor = SIMD3<Float>(Float(quadColorR), Float(quadColorG), Float(quadColorB))
        let quadWidth = Float(extractDoubleParameter(parameters, name: "quad_width", defaultValue: 1.0))

        // Create output RGBA texture
        let outputTexture = try createAnnotatedTexture(
            inputTexture: inputTexture,
            ellipses: drawEllipses ? ellipses : [],
            ellipseColor: ellipseColor,
            ellipseWidth: ellipseWidth,
            quads: drawQuads ? quads : [],
            quadColor: quadColor,
            quadWidth: quadWidth,
            device: device,
            commandQueue: commandQueue
        )

        // Update output frame
        if var outputFrame = outputs["annotated_frame"] as? Frame {
            outputFrame.texture = outputTexture
            outputs["annotated_frame"] = outputFrame
        }
    }

    // MARK: - Private Helper Methods

    private func extractDoubleParameter(_ parameters: [String: Parameter], name: String, defaultValue: Double) -> Double {
        if let param = parameters[name],
           case .double(let value) = param {
            return value
        }
        return defaultValue
    }

    private func extractBoolParameter(_ parameters: [String: Parameter], name: String, defaultValue: Bool) -> Bool {
        if let param = parameters[name] {
            switch param {
            case .int(let value):
                return value != 0
            case .double(let value):
                return value != 0.0
            case .string(let value):
                let lowercased = value.lowercased()
                return lowercased == "true" || lowercased == "1" || lowercased == "yes"
            }
        }
        return defaultValue
    }

    private func extractEllipses(from dataFrame: DataFrame) throws -> [StarEllipse] {
        guard let centroidXColumn = dataFrame.columns.first(where: { $0.name == "centroid_x" }),
              let centroidYColumn = dataFrame.columns.first(where: { $0.name == "centroid_y" }),
              let majorAxisColumn = dataFrame.columns.first(where: { $0.name == "major_axis" }),
              let minorAxisColumn = dataFrame.columns.first(where: { $0.name == "minor_axis" }),
              let rotationAngleColumn = dataFrame.columns.first(where: { $0.name == "rotation_angle" }) else {
            throw ProcessorExecutionError.executionFailed("Missing required columns in pixel_coordinates table")
        }

        // Prefer measured FWHM over the detection-blob axes: blob axes are sized for
        // measurement apertures (≈4σ) and draw far outside the visible star. The drawn
        // ellipse is the half-maximum contour, so its semi-axes are FWHM / 2.
        let fwhmMajorColumn = dataFrame.columns.first(where: { $0.name == "fwhm_major" })
        let fwhmMinorColumn = dataFrame.columns.first(where: { $0.name == "fwhm_minor" })

        var ellipses: [StarEllipse] = []
        for rowIndex in 0..<dataFrame.rows.count {
            guard let centroidX = centroidXColumn[rowIndex] as? Double,
                  let centroidY = centroidYColumn[rowIndex] as? Double,
                  let majorAxis = majorAxisColumn[rowIndex] as? Double,
                  let minorAxis = minorAxisColumn[rowIndex] as? Double,
                  let rotationAngle = rotationAngleColumn[rowIndex] as? Double else {
                continue
            }

            var semiMajor = majorAxis
            var semiMinor = minorAxis
            if let fwhmMajor = fwhmMajorColumn?[rowIndex] as? Double,
               let fwhmMinor = fwhmMinorColumn?[rowIndex] as? Double,
               fwhmMajor > 0, fwhmMinor > 0 {
                semiMajor = fwhmMajor / 2.0
                semiMinor = fwhmMinor / 2.0
            }

            ellipses.append(StarEllipse(
                centroidX: Float(centroidX),
                centroidY: Float(centroidY),
                majorAxis: Float(semiMajor),
                minorAxis: Float(semiMinor),
                rotationAngle: Float(rotationAngle)
            ))
        }

        return ellipses
    }

    private func extractQuads(from dataFrame: DataFrame) throws -> [QuadLine] {
        guard let s1XColumn = dataFrame.columns.first(where: { $0.name == "s1_x" }),
              let s1YColumn = dataFrame.columns.first(where: { $0.name == "s1_y" }),
              let s2XColumn = dataFrame.columns.first(where: { $0.name == "s2_x" }),
              let s2YColumn = dataFrame.columns.first(where: { $0.name == "s2_y" }),
              let s3XColumn = dataFrame.columns.first(where: { $0.name == "s3_x" }),
              let s3YColumn = dataFrame.columns.first(where: { $0.name == "s3_y" }),
              let s4XColumn = dataFrame.columns.first(where: { $0.name == "s4_x" }),
              let s4YColumn = dataFrame.columns.first(where: { $0.name == "s4_y" }) else {
            throw ProcessorExecutionError.executionFailed("Missing required columns in quads table")
        }

        var quads: [QuadLine] = []
        for rowIndex in 0..<dataFrame.rows.count {
            guard let s1X = s1XColumn[rowIndex] as? Double,
                  let s1Y = s1YColumn[rowIndex] as? Double,
                  let s2X = s2XColumn[rowIndex] as? Double,
                  let s2Y = s2YColumn[rowIndex] as? Double,
                  let s3X = s3XColumn[rowIndex] as? Double,
                  let s3Y = s3YColumn[rowIndex] as? Double,
                  let s4X = s4XColumn[rowIndex] as? Double,
                  let s4Y = s4YColumn[rowIndex] as? Double else {
                continue
            }

            quads.append(QuadLine(
                x1: Float(s1X),
                y1: Float(s1Y),
                x2: Float(s2X),
                y2: Float(s2Y),
                x3: Float(s3X),
                y3: Float(s3Y),
                x4: Float(s4X),
                y4: Float(s4Y)
            ))
        }

        return quads
    }

    private func createAnnotatedTexture(
        inputTexture: MTLTexture,
        ellipses: [StarEllipse],
        ellipseColor: SIMD3<Float>,
        ellipseWidth: Float,
        quads: [QuadLine],
        quadColor: SIMD3<Float>,
        quadWidth: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Create output texture with RGBA format
        let descriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: .rgba32Float,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(descriptor: descriptor, device: device)

        // Copy grayscale input to RGBA output
        try copyGrayscaleToRGBA(
            inputTexture: inputTexture,
            outputTexture: outputTexture,
            device: device,
            commandQueue: commandQueue
        )

        // Draw ellipses if provided
        if !ellipses.isEmpty {
            try drawEllipses(
                on: outputTexture,
                ellipses: ellipses,
                ellipseColor: ellipseColor,
                ellipseWidth: ellipseWidth,
                device: device,
                commandQueue: commandQueue
            )
        }

        // Draw quads if provided
        if !quads.isEmpty {
            try drawQuads(
                on: outputTexture,
                quads: quads,
                quadColor: quadColor,
                quadWidth: quadWidth,
                device: device,
                commandQueue: commandQueue
            )
        }

        return outputTexture
    }

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
        let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)

        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
    }

    private func drawEllipses(
        on texture: MTLTexture,
        ellipses: [StarEllipse],
        ellipseColor: SIMD3<Float>,
        ellipseWidth: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "draw_ellipses") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load draw_ellipses shader")
        }

        let pipelineState = try ProcessorHelpers.createComputePipelineState(function: function, device: device)

        // Create ellipse buffer (5 floats per ellipse)
        let ellipseData = ellipses.flatMap { ellipse -> [Float] in
            [ellipse.centroidX, ellipse.centroidY, ellipse.majorAxis, ellipse.minorAxis, ellipse.rotationAngle]
        }
        let ellipseBuffer = try ProcessorHelpers.createBuffer(data: ellipseData, device: device)

        // Create num ellipses buffer
        var numEllipses = Int32(ellipses.count)
        let numEllipsesBuffer = try ProcessorHelpers.createBuffer(from: &numEllipses, device: device)

        // Create color buffer
        let colorArray: [Float] = [ellipseColor.x, ellipseColor.y, ellipseColor.z]
        let colorBuffer = try ProcessorHelpers.createBuffer(data: colorArray, device: device)

        // Create width buffer
        var widthValue = ellipseWidth
        let widthBuffer = try ProcessorHelpers.createBuffer(from: &widthValue, device: device)

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBuffer(ellipseBuffer, offset: 0, index: 0)
        encoder.setBuffer(numEllipsesBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorBuffer, offset: 0, index: 2)
        encoder.setBuffer(widthBuffer, offset: 0, index: 3)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: texture)

        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
    }

    private func drawQuads(
        on texture: MTLTexture,
        quads: [QuadLine],
        quadColor: SIMD3<Float>,
        quadWidth: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let function = library.makeFunction(name: "draw_quads") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load draw_quads shader")
        }

        let pipelineState = try ProcessorHelpers.createComputePipelineState(function: function, device: device)

        // Create quad buffer (8 floats per quad)
        let quadData = quads.flatMap { quad -> [Float] in
            [quad.x1, quad.y1, quad.x2, quad.y2, quad.x3, quad.y3, quad.x4, quad.y4]
        }
        let quadBuffer = try ProcessorHelpers.createBuffer(data: quadData, device: device)

        // Create num quads buffer
        var numQuads = Int32(quads.count)
        let numQuadsBuffer = try ProcessorHelpers.createBuffer(from: &numQuads, device: device)

        // Create color buffer
        let colorArray: [Float] = [quadColor.x, quadColor.y, quadColor.z]
        let colorBuffer = try ProcessorHelpers.createBuffer(data: colorArray, device: device)

        // Create width buffer
        var widthValue = quadWidth
        let widthBuffer = try ProcessorHelpers.createBuffer(from: &widthValue, device: device)

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setBuffer(numQuadsBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorBuffer, offset: 0, index: 2)
        encoder.setBuffer(widthBuffer, offset: 0, index: 3)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: texture)

        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
    }
}

