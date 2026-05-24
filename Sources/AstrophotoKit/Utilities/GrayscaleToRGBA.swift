import Foundation
import Metal

public enum GrayscaleToRGBAError: LocalizedError {
    case metalNotSupported
    case couldNotCreateCommandQueue
    case couldNotLoadShaderLibrary
    case couldNotLoadComputeFunction
    case couldNotCreatePipelineState(Error)
    case couldNotCreateTexture
    case couldNotCreateCommandBuffer
    case couldNotCreateComputeEncoder
    case computeError(Error)

    public var errorDescription: String? {
        switch self {
        case .metalNotSupported: return "Metal is not supported on this device"
        case .couldNotCreateCommandQueue: return "Could not create Metal command queue"
        case .couldNotLoadShaderLibrary: return "Could not load Metal shader library"
        case .couldNotLoadComputeFunction: return "Could not load grayscale to RGBA compute function"
        case .couldNotCreatePipelineState(let error): return "Could not create compute pipeline state: \(error.localizedDescription)"
        case .couldNotCreateTexture: return "Could not create Metal texture"
        case .couldNotCreateCommandBuffer: return "Could not create Metal command buffer"
        case .couldNotCreateComputeEncoder: return "Could not create Metal compute encoder"
        case .computeError(let error): return "Compute shader error: \(error.localizedDescription)"
        }
    }
}

/// Converts grayscale textures (r32Float) to RGBA textures (rgba32Float)
/// This ensures all textures are in a consistent format for display and color overlays
public class GrayscaleToRGBA {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipelineState: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw GrayscaleToRGBAError.couldNotCreateCommandQueue
        }
        self.commandQueue = commandQueue

        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw GrayscaleToRGBAError.couldNotLoadShaderLibrary
        }

        guard let function = library.makeFunction(name: "copy_grayscale_to_rgba") else {
            throw GrayscaleToRGBAError.couldNotLoadComputeFunction
        }

        do {
            self.computePipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw GrayscaleToRGBAError.couldNotCreatePipelineState(error)
        }
    }

    /// Converts a grayscale texture to RGBA format
    /// - Parameter inputTexture: The grayscale texture (r32Float) to convert
    /// - Returns: A new RGBA texture (rgba32Float) with R=G=B values
    public func convert(_ inputTexture: MTLTexture) throws -> MTLTexture {
        // If already RGBA, return as-is
        if inputTexture.pixelFormat == .rgba32Float {
            return inputTexture
        }

        // Create output texture with RGBA format
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw GrayscaleToRGBAError.couldNotCreateTexture
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw GrayscaleToRGBAError.couldNotCreateCommandBuffer
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GrayscaleToRGBAError.couldNotCreateComputeEncoder
        }

        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw GrayscaleToRGBAError.computeError(error)
        }

        return outputTexture
    }
}

