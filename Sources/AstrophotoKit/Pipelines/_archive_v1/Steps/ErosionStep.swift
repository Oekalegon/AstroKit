import Foundation
import Metal

/// Pipeline step that applies binary erosion to an image
public class ErosionStep: PipelineStep {
    public let id: String = "erosion"
    public let name: String = "Erosion"
    public let description: String = "Applies binary erosion to shrink objects and remove noise"
    
    public let requiredInputs: [String] = ["thresholded_image"]
    public let optionalInputs: [String] = ["kernel_size"]
    public let outputs: [String] = ["eroded_image"]
    
    private let defaultKernelSize: Int
    
    /// Initialize the erosion step
    /// - Parameter defaultKernelSize: Default kernel size for erosion (must be odd, default: 3)
    public init(defaultKernelSize: Int = 3) {
        self.defaultKernelSize = defaultKernelSize
    }
    
    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        // Get input image (try thresholded_image first, then fall back to input_image for flexibility)
        guard let inputImageInput = inputs["thresholded_image"] ?? inputs["input_image"] else {
            throw PipelineStepError.missingRequiredInput("thresholded_image or input_image")
        }
        
        // Get kernel size (optional)
        let kernelSize: Int
        if let kernelSizeInput = inputs["kernel_size"] {
            guard let kernelSizeValue = kernelSizeInput.data.scalar else {
                throw PipelineStepError.invalidInputType("kernel_size", expected: "scalar")
            }
            kernelSize = Int(kernelSizeValue)
        } else {
            kernelSize = defaultKernelSize
        }
        
        // Validate kernel size
        guard kernelSize > 0 && kernelSize % 2 == 1 else {
            throw PipelineStepError.invalidInputType("kernel_size", expected: "positive odd integer")
        }
        
        // Get input ProcessedImage or create one from texture/FITSImage
        let inputProcessedImage: ProcessedImage
        if let processedImage = inputImageInput.data.processedImage {
            inputProcessedImage = processedImage
        } else if let texture = inputImageInput.data.texture {
            // Create ProcessedImage from texture
            let imageType = ProcessedImage.imageType(from: texture.pixelFormat)
            inputProcessedImage = ProcessedImage(
                texture: texture,
                imageType: imageType,
                originalMinValue: 0.0,
                originalMaxValue: 1.0,
                processingHistory: [],
                fitsImage: inputImageInput.data.fitsImage,
                name: inputImageInput.name
            )
        } else if let fitsImage = inputImageInput.data.fitsImage {
            inputProcessedImage = try ProcessedImage.fromFITSImage(fitsImage, device: device)
        } else {
            throw PipelineStepError.invalidInputType("input_image", expected: "processedImage, texture, or fitsImage")
        }
        
        // Apply erosion
        let erodedTexture = try applyErosion(
            texture: inputProcessedImage.texture,
            kernelSize: kernelSize,
            device: device,
            commandQueue: commandQueue
        )
        
        // Create output ProcessedImage with processing history
        let outputProcessedImage = inputProcessedImage.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: ["kernel_size": "\(kernelSize)"],
            newTexture: erodedTexture,
            newImageType: .binary, // Erosion produces binary images
            newName: "Eroded Image"
        )
        
        return [
            "eroded_image": PipelineStepOutput(
                name: "eroded_image",
                data: .processedImage(outputProcessedImage),
                description: "The eroded binary mask"
            )
        ]
    }
    
    // MARK: - Private Helper Methods
    
    private func applyErosion(
        texture: MTLTexture,
        kernelSize: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineStepError.couldNotCreateResource("output texture")
        }
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let function = library.makeFunction(name: "binary_erosion") else {
            throw PipelineStepError.couldNotCreateResource("binary_erosion function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Create buffer for kernel size
        var kernelSizeValue = Int32(kernelSize)
        guard let kernelSizeBuffer = device.makeBuffer(bytes: &kernelSizeValue, length: MemoryLayout<Int32>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("kernel size buffer")
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(kernelSizeBuffer, offset: 0, index: 0)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("GPU erosion failed: \(error.localizedDescription)")
        }
        
        return outputTexture
    }
}

