import Foundation
import Metal
import MetalKit

/// Errors that can occur during Gaussian blur computation
public enum GaussianBlurError: LocalizedError {
    case metalNotSupported
    case couldNotCreateCommandQueue
    case couldNotLoadShaderLibrary
    case couldNotLoadComputeFunction
    case couldNotCreatePipelineState(Error)
    case couldNotCreateTexture
    case couldNotCreateBuffer
    case couldNotCreateCommandBuffer
    case couldNotCreateComputeEncoder
    case computeError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .metalNotSupported:
            return "Metal is not supported on this device"
        case .couldNotCreateCommandQueue:
            return "Could not create Metal command queue"
        case .couldNotLoadShaderLibrary:
            return "Could not load Metal shader library"
        case .couldNotLoadComputeFunction:
            return "Could not load Gaussian blur compute function"
        case .couldNotCreatePipelineState(let error):
            return "Could not create compute pipeline state: \(error.localizedDescription)"
        case .couldNotCreateTexture:
            return "Could not create Metal texture"
        case .couldNotCreateBuffer:
            return "Could not create Metal buffer"
        case .couldNotCreateCommandBuffer:
            return "Could not create Metal command buffer"
        case .couldNotCreateComputeEncoder:
            return "Could not create Metal compute encoder"
        case .computeError(let error):
            return "Compute shader error: \(error.localizedDescription)"
        }
    }
}

/// Computes Gaussian blur on FITS images using Metal
public class GaussianBlur {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let horizontalPipelineState: MTLComputePipelineState
    private let verticalPipelineState: MTLComputePipelineState
    
    /// Initialize the Gaussian blur processor
    /// - Parameter device: Optional Metal device (uses default if nil)
    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw GaussianBlurError.metalNotSupported
        }
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw GaussianBlurError.couldNotCreateCommandQueue
        }
        self.commandQueue = commandQueue
        
        // Load the compute shaders
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw GaussianBlurError.couldNotLoadShaderLibrary
        }
        
        guard let horizontalFunction = library.makeFunction(name: "gaussian_blur_horizontal"),
              let verticalFunction = library.makeFunction(name: "gaussian_blur_vertical") else {
            throw GaussianBlurError.couldNotLoadComputeFunction
        }
        
        do {
            self.horizontalPipelineState = try device.makeComputePipelineState(function: horizontalFunction)
            self.verticalPipelineState = try device.makeComputePipelineState(function: verticalFunction)
        } catch {
            throw GaussianBlurError.couldNotCreatePipelineState(error)
        }
    }
    
    /// Applies Gaussian blur to a Metal texture
    /// - Parameters:
    ///   - inputTexture: The input Metal texture
    ///   - radius: Blur radius in pixels (default: 5.0)
    /// - Returns: A new Metal texture with the blurred result
    public func applyBlur(to inputTexture: MTLTexture, radius: Float = 5.0) throws -> MTLTexture {
        guard radius > 0 else {
            // Return original texture if radius is 0 or negative
            return inputTexture
        }
        
        // Create intermediate texture for horizontal pass
        let intermediateDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        intermediateDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let intermediateTexture = device.makeTexture(descriptor: intermediateDescriptor) else {
            throw GaussianBlurError.couldNotCreateTexture
        }
        
        // Create output texture
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw GaussianBlurError.couldNotCreateTexture
        }
        
        // Create buffer for radius parameter
        var radiusValue = radius
        guard let radiusBuffer = device.makeBuffer(bytes: &radiusValue, length: MemoryLayout<Float>.size, options: []) else {
            throw GaussianBlurError.couldNotCreateBuffer
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw GaussianBlurError.couldNotCreateCommandBuffer
        }
        
        // Pass 1: Horizontal blur (input -> intermediate)
        guard let horizontalEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GaussianBlurError.couldNotCreateComputeEncoder
        }
        
        horizontalEncoder.setComputePipelineState(horizontalPipelineState)
        horizontalEncoder.setTexture(inputTexture, index: 0)
        horizontalEncoder.setTexture(intermediateTexture, index: 1)
        horizontalEncoder.setBuffer(radiusBuffer, offset: 0, index: 0)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        horizontalEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        horizontalEncoder.endEncoding()
        
        // Pass 2: Vertical blur (intermediate -> output)
        guard let verticalEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GaussianBlurError.couldNotCreateComputeEncoder
        }
        
        verticalEncoder.setComputePipelineState(verticalPipelineState)
        verticalEncoder.setTexture(intermediateTexture, index: 0)
        verticalEncoder.setTexture(outputTexture, index: 1)
        verticalEncoder.setBuffer(radiusBuffer, offset: 0, index: 0)
        
        verticalEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        verticalEncoder.endEncoding()
        
        // Commit and wait for completion
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Check for errors
        if let error = commandBuffer.error {
            throw GaussianBlurError.computeError(error)
        }
        
        return outputTexture
    }
    
    /// Applies Gaussian blur to a FITS image
    /// - Parameters:
    ///   - fitsImage: The input FITS image
    ///   - radius: Blur radius in pixels (default: 5.0)
    /// - Returns: A new FITSImage with the blurred result
    public func applyBlur(to fitsImage: FITSImage, radius: Float = 5.0) throws -> FITSImage {
        // Create Metal texture from FITS image
        let inputTexture = try fitsImage.createMetalTexture(device: device, pixelFormat: .r32Float)
        
        // Apply blur
        let outputTexture = try applyBlur(to: inputTexture, radius: radius)
        
        // Read back pixel data from output texture using a blit encoder
        let width = outputTexture.width
        let height = outputTexture.height
        let bytesPerRow = width * MemoryLayout<Float32>.size
        let bufferSize = bytesPerRow * height
        
        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw GaussianBlurError.couldNotCreateBuffer
        }
        
        // Create a new command buffer for reading
        guard let readCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw GaussianBlurError.couldNotCreateCommandBuffer
        }
        
        guard let blitEncoder = readCommandBuffer.makeBlitCommandEncoder() else {
            throw GaussianBlurError.couldNotCreateComputeEncoder
        }
        
        blitEncoder.copy(from: outputTexture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: width, height: height, depth: 1),
                        to: readBuffer,
                        destinationOffset: 0,
                        destinationBytesPerRow: bytesPerRow,
                        destinationBytesPerImage: bufferSize)
        blitEncoder.endEncoding()
        
        readCommandBuffer.commit()
        readCommandBuffer.waitUntilCompleted()
        
        if let error = readCommandBuffer.error {
            throw GaussianBlurError.computeError(error)
        }
        
        // Copy data from buffer to array
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: width * height)
        let pixelData = Array(UnsafeBufferPointer(start: pixelPointer, count: width * height))
        
        // Create raw data
        let rawData = pixelData.withUnsafeBytes { Data($0) }
        
        // Create new FITSImage with blurred data
        // Keep the same metadata and value range as the original
        return FITSImage(
            width: width,
            height: height,
            depth: fitsImage.depth,
            bitpix: fitsImage.bitpix,
            dataType: fitsImage.dataType,
            pixelData: pixelData,
            rawData: rawData,
            originalMinValue: fitsImage.originalMinValue,
            originalMaxValue: fitsImage.originalMaxValue,
            metadata: fitsImage.metadata
        )
    }
}

