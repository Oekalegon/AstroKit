import Foundation
import Metal
import os

/// Processor for converting frames to grayscale
public struct GrayscaleProcessor: Processor {

    public var id: String { "grayscale" }

    public init() {}

    /// Execute the grayscale processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing "grayscale_frame" -> ProcessData (Frame, to be instantiated)
    ///   - parameters: Dictionary (empty for this processor)
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

        Logger.processor.debug(
            "Converting frame to grayscale (width: \(inputTexture.width), height: \(inputTexture.height))"
        )

        // Load shader library and function
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let grayscaleFunction = library.makeFunction(name: "grayscale") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load grayscale shader function")
        }

        // Create compute pipeline state
        let computePipelineState = try ProcessorHelpers.createComputePipelineState(
            function: grayscaleFunction,
            device: device
        )

        // Create output texture (grayscale format: r32Float)
        let outputDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: .r32Float,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(
            descriptor: outputDescriptor,
            device: device
        )

        // Create command buffer and encoder
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let computeEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)

        // Calculate and dispatch threadgroups
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        // Execute command buffer
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        // Update output frame
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "grayscale_frame",
            texture: outputTexture
        )

        Logger.processor.debug("Grayscale conversion completed successfully")
    }
}
