import Foundation
import Metal
import os

/// Processor for applying threshold to frames to create binary masks
public struct ThresholdProcessor: Processor {

    public var id: String { "threshold" }

    public init() {}

    /// Execute the threshold processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing "thresholded_frame" -> ProcessData (Frame, to be instantiated)
    ///   - parameters: Dictionary containing:
    ///     - "threshold_value" -> Parameter (Double, default: 3.0) - sigma multiplier for sigma method
    ///     - "method" -> Parameter (String, default: "sigma") - threshold method
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

        // Get and validate parameters
        let (thresholdValue, method) = try extractParameters(from: parameters)

        Logger.processor.debug(
            "Applying threshold with method: \(method), threshold_value: \(thresholdValue)"
        )

        // Calculate actual threshold based on method
        let actualThreshold = try calculateThreshold(
            method: method,
            thresholdValue: thresholdValue,
            texture: inputTexture,
            device: device,
            commandQueue: commandQueue
        )

        // Apply threshold using Metal shader
        let outputTexture = try applyThresholdShader(
            inputTexture: inputTexture,
            threshold: actualThreshold,
            device: device,
            commandQueue: commandQueue
        )

        // Update output frame
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "thresholded_frame",
            texture: outputTexture
        )

        Logger.processor.info("Threshold completed successfully (threshold: \(actualThreshold))")
    }

    /// Extract and validate parameters from the parameters dictionary
    private func extractParameters(
        from parameters: [String: Parameter]
    ) throws -> (thresholdValue: Double, method: String) {
        let thresholdValue: Double
        if let thresholdParam = parameters["threshold_value"] {
            if let doubleValue = thresholdParam.doubleValue {
                thresholdValue = doubleValue
            } else {
                throw ProcessorExecutionError.executionFailed("threshold_value parameter must be a number")
            }
        } else {
            thresholdValue = 3.0  // Default from YAML
        }

        let method: String
        if let methodParam = parameters["method"] {
            method = methodParam.stringValue
        } else {
            method = "sigma"  // Default from YAML
        }

        return (thresholdValue, method)
    }

    /// Calculate the actual threshold value based on the method
    private func calculateThreshold(
        method: String,
        thresholdValue: Double,
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        switch method {
        case "sigma":
            // Calculate mean and stddev, then threshold = mean + N * sigma
            let (mean, stdDev) = try calculateMeanAndStdDev(
                texture: texture,
                device: device,
                commandQueue: commandQueue
            )
            let actualThreshold = mean + Float(thresholdValue) * stdDev
            Logger.processor.debug(
                "Calculated sigma threshold: \(actualThreshold) (mean: \(mean), stddev: \(stdDev))"
            )
            return actualThreshold
        case "fixed":
            let actualThreshold = Float(thresholdValue)
            Logger.processor.debug("Using fixed threshold: \(actualThreshold)")
            return actualThreshold
        default:
            throw ProcessorExecutionError.executionFailed("Unsupported threshold method: \(method)")
        }
    }

    /// Apply threshold shader to create binary mask
    private func applyThresholdShader(
        inputTexture: MTLTexture,
        threshold: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Load shader library and function
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let thresholdFunction = library.makeFunction(name: "threshold") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load threshold shader function")
        }

        // Create compute pipeline state
        let computePipelineState = try ProcessorHelpers.createComputePipelineState(
            function: thresholdFunction,
            device: device
        )

        // Create output texture (binary format: same as input)
        let outputDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(
            descriptor: outputDescriptor,
            device: device
        )

        // Create buffer for threshold value
        var thresholdValueFloat = threshold
        let thresholdBuffer = try ProcessorHelpers.createBuffer(from: &thresholdValueFloat, device: device)

        // Create command buffer and encoder
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let computeEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        computeEncoder.setBuffer(thresholdBuffer, offset: 0, index: 0)

        // Calculate and dispatch threadgroups
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        // Execute command buffer
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        return outputTexture
    }

    /// Calculate mean and standard deviation from texture
    /// - Parameters:
    ///   - texture: The input texture
    ///   - device: Metal device
    ///   - commandQueue: Metal command queue
    /// - Returns: Tuple of (mean, stdDev)
    /// - Throws: ProcessorExecutionError if calculation fails
    private func calculateMeanAndStdDev(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> (mean: Float, stdDev: Float) {
        // Sample a subset of pixels for performance (every 10th pixel)
        let sampleRate = 10
        let width = texture.width
        let height = texture.height
        let sampleWidth = max(1, width / sampleRate)
        let sampleHeight = max(1, height / sampleRate)
        let bytesPerRow = sampleWidth * MemoryLayout<Float32>.size
        let bufferSize = bytesPerRow * sampleHeight

        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create read buffer")
        }

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create blit encoder")
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sampleWidth, height: sampleHeight, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        // Calculate mean and stddev from sample
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: sampleWidth * sampleHeight)
        let pixels = Array(UnsafeBufferPointer(start: pixelPointer, count: sampleWidth * sampleHeight))

        let count = Float(pixels.count)
        let sum = pixels.reduce(0.0, +)
        let mean = sum / count

        let variance = pixels.map { pow($0 - mean, 2) }.reduce(0.0, +) / count
        let stdDev = sqrt(max(0.0, variance))  // Ensure non-negative

        return (mean, stdDev)
    }
}
