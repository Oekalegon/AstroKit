import Foundation
import Metal

/// Filter for binary erosion morphological operation
/// Erosion shrinks objects by removing pixels from boundaries
public class BinaryErosion {
    private let device: MTLDevice
    private let pipelineState: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue
    
    /// Initialize the binary erosion filter
    /// - Parameters:
    ///   - device: Metal device to use for computation
    ///   - kernelSize: Size of the structuring element (must be odd, default: 3)
    /// - Throws: Error if Metal resources cannot be created
    public init(device: MTLDevice, kernelSize: Int = 3) throws {
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw NSError(domain: "BinaryErosion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create command queue"])
        }
        self.commandQueue = commandQueue
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw NSError(domain: "BinaryErosion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not load shader library"])
        }
        
        guard let function = library.makeFunction(name: "binary_erosion") else {
            throw NSError(domain: "BinaryErosion", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not find binary_erosion function"])
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw NSError(domain: "BinaryErosion", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create compute pipeline state"])
        }
        self.pipelineState = pipelineState
    }
    
    /// Apply binary erosion to a texture
    /// - Parameters:
    ///   - inputTexture: Input texture (binary mask, 0 or 1 values)
    ///   - kernelSize: Size of the structuring element (must be odd)
    /// - Returns: Eroded output texture
    /// - Throws: Error if erosion operation fails
    public func apply(to inputTexture: MTLTexture, kernelSize: Int) throws -> MTLTexture {
        // Validate kernel size
        guard kernelSize > 0 && kernelSize % 2 == 1 else {
            throw NSError(domain: "BinaryErosion", code: 5, userInfo: [NSLocalizedDescriptionKey: "Kernel size must be positive and odd"])
        }
        
        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "BinaryErosion", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not create output texture"])
        }
        
        // Create buffer for kernel size
        var kernelSizeValue = Int32(kernelSize)
        guard let kernelSizeBuffer = device.makeBuffer(bytes: &kernelSizeValue, length: MemoryLayout<Int32>.size, options: []) else {
            throw NSError(domain: "BinaryErosion", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not create kernel size buffer"])
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "BinaryErosion", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create command buffer"])
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "BinaryErosion", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not create compute encoder"])
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(kernelSizeBuffer, offset: 0, index: 0)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw NSError(domain: "BinaryErosion", code: 10, userInfo: [NSLocalizedDescriptionKey: "GPU erosion failed: \(error.localizedDescription)"])
        }
        
        return outputTexture
    }
}

