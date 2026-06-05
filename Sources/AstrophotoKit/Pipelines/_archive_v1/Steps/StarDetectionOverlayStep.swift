import Foundation
import Metal

/// Pipeline step that draws ellipses and quads around detected stars on the original image
public class StarDetectionOverlayStep: PipelineStep {
    public let id: String = "star_detection_overlay"
    public let name: String = "Star Detection Overlay"
    public let description: String = "Draws ellipses and quads around detected stars on the original image"

    public let requiredInputs: [String] = ["input_image", "pixel_coordinates"]
    public let optionalInputs: [String] = [
        "ellipse_color_r", "ellipse_color_g", "ellipse_color_b", "ellipse_width",
        "quads", "quad_color_r", "quad_color_g", "quad_color_b", "quad_width"
    ]
    public let outputs: [String] = ["annotated_image"]

    public init() {
    }

    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        // Get original input image
        guard let inputImageInput = inputs["input_image"] else {
            throw PipelineStepError.missingRequiredInput("input_image")
        }

        // Get component properties table
        guard let componentTableInput = inputs["pixel_coordinates"] else {
            throw PipelineStepError.missingRequiredInput("pixel_coordinates")
        }

        // Get component table (can be ProcessedTable or legacy table)
        let componentTable: [String: Any]
        if let processedTable = componentTableInput.data.processedTable {
            componentTable = processedTable.data
        } else if let table = componentTableInput.data.table {
            componentTable = table
        } else {
            throw PipelineStepError.invalidInputType("pixel_coordinates", expected: "processedTable or table")
        }

        // Get the original input image's ProcessedImage (for history tracking)
        let baseProcessedImage: ProcessedImage
        if let processedImage = inputImageInput.data.processedImage {
            baseProcessedImage = processedImage
        } else if let texture = inputImageInput.data.texture {
            // Create ProcessedImage from texture
            let imageType = ProcessedImage.imageType(from: texture.pixelFormat)
            baseProcessedImage = ProcessedImage(
                texture: texture,
                imageType: imageType,
                originalMinValue: 0.0,
                originalMaxValue: 1.0,
                processingHistory: [],
                fitsImage: inputImageInput.data.fitsImage,
                name: inputImageInput.name
            )
        } else if let fitsImage = inputImageInput.data.fitsImage {
            baseProcessedImage = try ProcessedImage.fromFITSImage(fitsImage, device: device)
        } else {
            throw PipelineStepError.invalidInputType("input_image", expected: "processedImage, texture, or fitsImage")
        }
        
        // Use the original input_image's texture for drawing
        let inputTexture: MTLTexture
        if let processedImage = inputImageInput.data.processedImage {
            inputTexture = processedImage.texture
        } else if let texture = inputImageInput.data.texture {
            inputTexture = texture
        } else if let fitsImage = inputImageInput.data.fitsImage {
            inputTexture = try fitsImage.createMetalTexture(device: device, pixelFormat: .r32Float)
        } else {
            throw PipelineStepError.invalidInputType("input_image", expected: "processedImage, texture, or fitsImage")
        }
        
        // Build complete history from pipeline steps (focus on steps, not images)
        // Extract processing history from previous steps in the pipeline structure
        var combinedHistory: [ProcessingStep] = []
        
        if let contextInput = inputs["_pipeline_context"],
           let contextMetadata = contextInput.data.metadata,
           let previousStepOutputs = contextMetadata["previous_steps"] as? [[String: Any]] {
            // Iterate through each pipeline step in order
            for stepInfo in previousStepOutputs {
                // Get the most complete history from this step's outputs
                // (prefer ProcessedImage, then ProcessedTable, take the one with most history)
                var bestHistory: [ProcessingStep] = []
                
                if let outputs = stepInfo["outputs"] as? [String: [String: Any]] {
                    for (_, outputData) in outputs {
                        if let historyData = outputData["processing_history"] as? [[String: Any]] {
                            var stepHistory: [ProcessingStep] = []
                            for stepData in historyData {
                                if let stepID = stepData["step_id"] as? String,
                                   let stepName = stepData["step_name"] as? String,
                                   let parameters = stepData["parameters"] as? [String: String],
                                   let order = stepData["order"] as? Int {
                                    stepHistory.append(ProcessingStep(
                                        stepID: stepID,
                                        stepName: stepName,
                                        parameters: parameters,
                                        order: order
                                    ))
                                }
                            }
                            // Use the history with the most steps (most complete)
                            if stepHistory.count > bestHistory.count {
                                bestHistory = stepHistory
                            }
                        }
                    }
                }
                
                // Add all steps from this pipeline step's history
                // Only add steps we don't already have (by stepID and order)
                for step in bestHistory {
                    if !combinedHistory.contains(where: { $0.stepID == step.stepID && $0.order == step.order }) {
                        combinedHistory.append(step)
                    }
                }
            }
            
            // Sort by order to ensure correct sequence
            combinedHistory.sort { $0.order < $1.order }
        }
        
        // Create ProcessedImage with history from pipeline steps
        let inputProcessedImage: ProcessedImage
        if !combinedHistory.isEmpty {
            // Create a new ProcessedImage with the combined history from pipeline steps
            inputProcessedImage = ProcessedImage(
                texture: baseProcessedImage.texture,
                imageType: baseProcessedImage.imageType,
                originalMinValue: baseProcessedImage.originalMinValue,
                originalMaxValue: baseProcessedImage.originalMaxValue,
                processingHistory: combinedHistory,
                fitsImage: baseProcessedImage.fitsImage,
                name: baseProcessedImage.name
            )
        } else {
            // Fall back to base image if no pipeline history available
            inputProcessedImage = baseProcessedImage
        }

        // Extract ellipse parameters from component table
        guard let components = componentTable["components"] as? [[String: Any]] else {
            throw PipelineStepError.executionFailed("Invalid component table format")
        }

        // Convert component properties to ellipses
        var ellipses: [StarEllipse] = []
        for component in components {
            guard let centroid = component["centroid"] as? [String: Any],
                  let centroidX = centroid["x"] as? Double,
                  let centroidY = centroid["y"] as? Double,
                  let majorAxis = component["major_axis"] as? Double,
                  let minorAxis = component["minor_axis"] as? Double,
                  let rotationAngle = component["rotation_angle"] as? Double else {
                continue
            }

            ellipses.append(StarEllipse(
                centroidX: Float(centroidX),
                centroidY: Float(centroidY),
                majorAxis: Float(majorAxis),
                minorAxis: Float(minorAxis),
                rotationAngle: Float(rotationAngle)
            ))
        }

        // Get optional parameters
        let ellipseColorR = (inputs["ellipse_color_r"]?.data.scalar ?? 1.0)
        let ellipseColorG = (inputs["ellipse_color_g"]?.data.scalar ?? 0.0)
        let ellipseColorB = (inputs["ellipse_color_b"]?.data.scalar ?? 0.0)
        let ellipseColor = SIMD3<Float>(ellipseColorR, ellipseColorG, ellipseColorB)
        let ellipseWidth = inputs["ellipse_width"]?.data.scalar ?? 1.0 // Always 1 pixel wide

        // Extract quads if available
        var quads: [QuadLine] = []
        if let quadsInput = inputs["quads"] {
            let quadsTable: [String: Any]
            if let processedTable = quadsInput.data.processedTable {
                quadsTable = processedTable.data
            } else if let table = quadsInput.data.table {
                quadsTable = table
            } else {
                quadsTable = [:]
            }
            
            // Extract all quads from seed quads
            if let seedQuads = quadsTable["quads"] as? [[String: Any]] {
                for seedQuad in seedQuads {
                    if let quadLists = seedQuad["quad_lists"] as? [[String: Any]] {
                        for quadData in quadLists {
                            // Extract image coordinates for the 4 stars
                            if let s1Image = quadData["s1_image"] as? [Double], s1Image.count >= 2,
                               let s2Image = quadData["s2_image"] as? [Double], s2Image.count >= 2,
                               let s3Image = quadData["s3_image"] as? [Double], s3Image.count >= 2,
                               let s4Image = quadData["s4_image"] as? [Double], s4Image.count >= 2 {
                                // Create a quad with 4 points: connect S1->S2->S3->S4->S1
                                quads.append(QuadLine(
                                    x1: Float(s1Image[0]),
                                    y1: Float(s1Image[1]),
                                    x2: Float(s2Image[0]),
                                    y2: Float(s2Image[1]),
                                    x3: Float(s3Image[0]),
                                    y3: Float(s3Image[1]),
                                    x4: Float(s4Image[0]),
                                    y4: Float(s4Image[1])
                                ))
                            }
                        }
                    }
                }
            }
        }

        // Get quad color parameters (default to green)
        let quadColorR = (inputs["quad_color_r"]?.data.scalar ?? 0.0)
        let quadColorG = (inputs["quad_color_g"]?.data.scalar ?? 1.0)
        let quadColorB = (inputs["quad_color_b"]?.data.scalar ?? 0.0)
        let quadColor = SIMD3<Float>(quadColorR, quadColorG, quadColorB)
        let quadWidth = inputs["quad_width"]?.data.scalar ?? 1.0

        // Create star detection overlay filter and apply
        let overlay = try StarDetectionOverlay(device: device)
        let annotatedTexture = try overlay.apply(
            to: inputTexture,
            ellipses: ellipses,
            ellipseColor: ellipseColor,
            ellipseWidth: ellipseWidth,
            quads: quads,
            quadColor: quadColor,
            quadWidth: quadWidth
        )
        
        // Create output ProcessedImage with processing history
        let parameters: [String: String] = [
            "ellipse_count": "\(ellipses.count)",
            "ellipse_color_r": "\(ellipseColorR)",
            "ellipse_color_g": "\(ellipseColorG)",
            "ellipse_color_b": "\(ellipseColorB)",
            "ellipse_width": "\(ellipseWidth)",
            "quad_count": "\(quads.count)",
            "quad_color_r": "\(quadColorR)",
            "quad_color_g": "\(quadColorG)",
            "quad_color_b": "\(quadColorB)",
            "quad_width": "\(quadWidth)"
        ]
        
        let outputProcessedImage = inputProcessedImage.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: parameters,
            newTexture: annotatedTexture,
            newImageType: .rgba, // Ellipse overlay produces RGBA (color) images
            newName: "Annotated Image"
        )
        
        return [
            "annotated_image": PipelineStepOutput(
                name: "annotated_image",
                data: .processedImage(outputProcessedImage),
                description: "Original image with ellipses drawn around detected stars"
            )
        ]
    }
}

