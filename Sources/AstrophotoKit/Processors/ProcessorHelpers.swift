import Foundation
import Metal
import os

/// Helper utilities for processor implementations
/// Provides common Metal operations and validation to reduce code duplication
public enum ProcessorHelpers {

    /// Validates and extracts input frame from processor inputs
    /// - Parameter inputs: Dictionary of processor inputs
    /// - Returns: Tuple of (inputFrame, inputTexture)
    /// - Throws: ProcessorExecutionError if input is missing or invalid
    public static func validateInputFrame(
        from inputs: [String: ProcessData]
    ) throws -> (Frame, MTLTexture) {
        guard let inputFrame = inputs["input_frame"] as? Frame else {
            throw ProcessorExecutionError.missingRequiredInput("input_frame")
        }

        guard let inputTexture = inputFrame.texture else {
            throw ProcessorExecutionError.executionFailed("Input frame texture is not available")
        }

        return (inputFrame, inputTexture)
    }

    /// Loads the Metal shader library
    /// - Parameter device: Metal device
    /// - Returns: The shader library
    /// - Throws: ProcessorExecutionError if library cannot be loaded
    public static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load Metal shader library")
        }
        return library
    }

    /// Creates a compute pipeline state from a shader function
    /// - Parameters:
    ///   - function: The Metal compute function
    ///   - device: Metal device
    /// - Returns: The compute pipeline state
    /// - Throws: ProcessorExecutionError if pipeline state cannot be created
    public static func createComputePipelineState(
        function: MTLFunction,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not create compute pipeline state: \(error.localizedDescription)"
            )
        }
    }

    /// Creates a 2D texture descriptor with standard settings
    /// - Parameters:
    ///   - pixelFormat: The pixel format
    ///   - width: Texture width
    ///   - height: Texture height
    /// - Returns: Configured texture descriptor
    public static func createTextureDescriptor(
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        return descriptor
    }

    /// Creates a texture from a descriptor
    /// - Parameters:
    ///   - descriptor: The texture descriptor
    ///   - device: Metal device
    /// - Returns: The created texture
    /// - Throws: ProcessorExecutionError if texture cannot be created
    public static func createTexture(
        descriptor: MTLTextureDescriptor,
        device: MTLDevice
    ) throws -> MTLTexture {
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create texture")
        }
        return texture
    }

    /// Creates a Metal buffer from a value
    /// - Parameters:
    ///   - value: The value to create buffer from (must be a value type)
    ///   - device: Metal device
    /// - Returns: The created buffer
    /// - Throws: ProcessorExecutionError if buffer cannot be created
    public static func createBuffer<T>(
        from value: inout T,
        device: MTLDevice
    ) throws -> MTLBuffer where T: Any {
        return try withUnsafePointer(to: &value) { pointer in
            guard let buffer = device.makeBuffer(
                bytes: UnsafeRawPointer(pointer),
                length: MemoryLayout<T>.size,
                options: []
            ) else {
                throw ProcessorExecutionError.couldNotCreateResource("Could not create buffer")
            }
            return buffer
        }
    }

    /// Creates a Metal buffer from an array
    /// - Parameters:
    ///   - data: The array data to create buffer from
    ///   - device: Metal device
    /// - Returns: The created buffer
    /// - Throws: ProcessorExecutionError if buffer cannot be created
    public static func createBuffer<T>(
        data: [T],
        device: MTLDevice
    ) throws -> MTLBuffer {
        guard !data.isEmpty else {
            throw ProcessorExecutionError.couldNotCreateResource("Cannot create buffer from empty array")
        }
        let length = data.count * MemoryLayout<T>.stride
        let buffer = data.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: length, options: [])
        }
        guard let buffer else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create buffer")
        }
        return buffer
    }

    /// Creates a command buffer from a command queue
    /// - Parameter commandQueue: Metal command queue
    /// - Returns: The command buffer
    /// - Throws: ProcessorExecutionError if command buffer cannot be created
    public static func createCommandBuffer(
        commandQueue: MTLCommandQueue
    ) throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create command buffer")
        }
        return commandBuffer
    }

    /// Creates a compute command encoder from a command buffer
    /// - Parameter commandBuffer: Metal command buffer
    /// - Returns: The compute encoder
    /// - Throws: ProcessorExecutionError if encoder cannot be created
    public static func createComputeEncoder(
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLComputeCommandEncoder {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create compute encoder")
        }
        return encoder
    }

    /// Calculates threadgroup size and threadgroups per grid for a texture
    /// - Parameter texture: The texture to calculate for
    /// - Returns: Tuple of (threadgroupSize, threadgroupsPerGrid)
    public static func calculateThreadgroups(for texture: MTLTexture) -> (
        threadgroupSize: MTLSize,
        threadgroupsPerGrid: MTLSize
    ) {
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        return (threadgroupSize, threadgroupsPerGrid)
    }

    /// Executes a command buffer and checks for errors
    /// - Parameter commandBuffer: The command buffer to execute
    /// - Throws: ProcessorExecutionError if execution fails
    public static func executeCommandBuffer(
        _ commandBuffer: MTLCommandBuffer
    ) throws {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw ProcessorExecutionError.executionFailed(
                "GPU compute error: \(error.localizedDescription)"
            )
        }
    }

    /// Updates an output frame with a texture
    /// - Parameters:
    ///   - outputs: Dictionary of processor outputs (inout)
    ///   - outputName: Name of the output frame
    ///   - texture: The texture to assign to the frame
    /// - Throws: ProcessorExecutionError if output frame is missing
    public static func updateOutputFrame(
        outputs: inout [String: ProcessData],
        outputName: String,
        texture: MTLTexture
    ) throws {
        guard var outputFrame = outputs[outputName] as? Frame else {
            throw ProcessorExecutionError.missingRequiredInput(outputName)
        }

        // Modify the existing frame instead of creating a new one (to preserve identifier)
        // Update the texture - instantiatedAt will be set automatically when texture is set (via didSet)
        outputFrame.texture = texture

        // Update the outputs dictionary with the modified frame
        outputs[outputName] = outputFrame
    }
}

