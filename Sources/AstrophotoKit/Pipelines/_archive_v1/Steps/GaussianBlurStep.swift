import Foundation
import Metal

/// Pipeline step that applies Gaussian blur to an image
public class GaussianBlurStep: PipelineStep {
    public let id: String = "gaussian_blur"
    public let name: String = "Gaussian Blur"
    public let description: String = "Applies Gaussian blur to reduce noise and smooth the image"
    
    public let requiredInputs: [String] = ["input_image"]
    public let optionalInputs: [String] = ["radius"]
    public let outputs: [String] = ["blurred_image"]
    
    private let defaultRadius: Float
    
    /// Initialize the Gaussian blur step
    /// - Parameter defaultRadius: Default blur radius (default: 5.0)
    public init(defaultRadius: Float = 5.0) {
        self.defaultRadius = defaultRadius
    }
    
    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        // Get input image
        guard let inputImageInput = inputs["input_image"] else {
            throw PipelineStepError.missingRequiredInput("input_image")
        }
        
        // Get radius (optional)
        let radius: Float
        if let radiusInput = inputs["radius"] {
            guard let radiusValue = radiusInput.data.scalar else {
                throw PipelineStepError.invalidInputType("radius", expected: "scalar")
            }
            radius = radiusValue
        } else {
            radius = defaultRadius
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
        
        // Apply blur
        let blur = try GaussianBlur(device: device)
        let blurredTexture = try blur.applyBlur(to: inputProcessedImage.texture, radius: radius)
        
        // Create output ProcessedImage with processing history
        let outputProcessedImage = inputProcessedImage.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: ["radius": "\(radius)"],
            newTexture: blurredTexture,
            newImageType: inputProcessedImage.imageType, // Blur preserves image type
            newName: "Blurred Image"
        )
        
        return [
            "blurred_image": PipelineStepOutput(
                name: "blurred_image",
                data: .processedImage(outputProcessedImage),
                description: "The blurred output image"
            )
        ]
    }
}

