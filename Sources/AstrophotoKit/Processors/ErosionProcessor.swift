import Foundation
import Metal
import os

/// Processor for applying binary erosion to frames
public struct ErosionProcessor: Processor {

    public var id: String { "erosion" }

    public init() {}

    /// Execute the erosion processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing "eroded_frame" -> ProcessData (Frame, to be instantiated)
    ///   - parameters: Dictionary containing:
    ///     - "kernel_size" -> Parameter (Int, default: 3) - size of the erosion kernel
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

        // Get kernel size parameter
        let kernelSize: Int32
        if let kernelSizeParam = parameters["kernel_size"] {
            if let intValue = kernelSizeParam.intValue {
                kernelSize = Int32(intValue)
            } else if let doubleValue = kernelSizeParam.doubleValue {
                kernelSize = Int32(doubleValue)
            } else {
                throw ProcessorExecutionError.executionFailed("kernel_size parameter must be a number")
            }
        } else {
            kernelSize = 3  // Default from YAML
        }

        Logger.processor.debug("Applying binary erosion with kernel size: \(kernelSize)")

        // Load shader library and function
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let erosionFunction = library.makeFunction(name: "binary_erosion") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load binary_erosion shader function")
        }

        // Create compute pipeline state
        let computePipelineState = try ProcessorHelpers.createComputePipelineState(
            function: erosionFunction,
            device: device
        )

        // Create output texture (same format as input)
        let outputDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(
            descriptor: outputDescriptor,
            device: device
        )

        // Create buffer for kernel size
        var kernelSizeInt = kernelSize
        let kernelSizeBuffer = try ProcessorHelpers.createBuffer(from: &kernelSizeInt, device: device)

        // Create command buffer and encoder
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let computeEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        computeEncoder.setBuffer(kernelSizeBuffer, offset: 0, index: 0)

        // Calculate and dispatch threadgroups
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        // Execute command buffer
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        // Update output frame
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "eroded_frame",
            texture: outputTexture
        )

        Logger.processor.info("Erosion completed successfully (kernel size: \(kernelSize))")
    }
}

