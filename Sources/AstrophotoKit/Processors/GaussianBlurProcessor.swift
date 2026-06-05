import Foundation
import Metal
import os

/// Processor for applying Gaussian blur to frames
public struct GaussianBlurProcessor: Processor {

    public var id: String { "gaussian_blur" }

    public init() {}

    /// Execute the Gaussian blur processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing "blurred_frame" -> ProcessData (Frame, to be instantiated)
    ///   - parameters: Dictionary containing "radius" -> Parameter (Double, default: 3.0)
    ///   - device: Metal device for GPU operations
    ///   - commandQueue: Metal command queue for GPU operations
    /// - Throws: ProcessorExecutionError if execution fails
    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Validate input frame
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        // Get radius parameter (default: 3.0)
        let radius: Float
        if let radiusParam = parameters["radius"] {
            if let doubleValue = radiusParam.doubleValue {
                radius = Float(doubleValue)
            } else {
                throw ProcessorExecutionError.executionFailed("Radius parameter must be a number")
            }
        } else {
            radius = 3.0  // Default from YAML
        }

        Logger.processor.debug("Applying Gaussian blur with radius: \(radius)")

        // Load shader library and functions
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let horizontalFunction = library.makeFunction(name: "gaussian_blur_horizontal"),
              let verticalFunction = library.makeFunction(name: "gaussian_blur_vertical") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load Gaussian blur shader functions"
            )
        }

        // Create compute pipeline states
        let horizontalPipelineState = try ProcessorHelpers.createComputePipelineState(
            function: horizontalFunction,
            device: device
        )
        let verticalPipelineState = try ProcessorHelpers.createComputePipelineState(
            function: verticalFunction,
            device: device
        )

        // Create textures
        let intermediateDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let intermediateTexture = try ProcessorHelpers.createTexture(
            descriptor: intermediateDescriptor,
            device: device
        )

        let outputDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(
            descriptor: outputDescriptor,
            device: device
        )

        // Create buffer for radius parameter
        var radiusValue = radius
        let radiusBuffer = try ProcessorHelpers.createBuffer(from: &radiusValue, device: device)

        // Create command buffer
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)

        // Calculate threadgroups
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)

        // Pass 1: Horizontal blur (input -> intermediate)
        let horizontalEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)
        horizontalEncoder.setComputePipelineState(horizontalPipelineState)
        horizontalEncoder.setTexture(inputTexture, index: 0)
        horizontalEncoder.setTexture(intermediateTexture, index: 1)
        horizontalEncoder.setBuffer(radiusBuffer, offset: 0, index: 0)
        horizontalEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        horizontalEncoder.endEncoding()

        // Pass 2: Vertical blur (intermediate -> output)
        let verticalEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)
        verticalEncoder.setComputePipelineState(verticalPipelineState)
        verticalEncoder.setTexture(intermediateTexture, index: 0)
        verticalEncoder.setTexture(outputTexture, index: 1)
        verticalEncoder.setBuffer(radiusBuffer, offset: 0, index: 0)
        verticalEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        verticalEncoder.endEncoding()

        // Execute command buffer
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        // Update output frame
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "blurred_frame",
            texture: outputTexture
        )

        Logger.processor.debug("Gaussian blur completed successfully")
    }
}

