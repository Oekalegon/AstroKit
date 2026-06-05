import Foundation
import Metal
import os

/// Executes pipelines on images or sets of images
public class PipelineExecutor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    /// Cache of processed images to enable reuse across pipelines
    /// Key: A string identifier based on processing history
    /// Value: The ProcessedImage
    private var processedImageCache: [String: ProcessedImage] = [:]
    
    /// Initialize the pipeline executor
    /// - Parameter device: Optional Metal device (uses default if nil)
    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw PipelineError.metalNotAvailable
        }
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw PipelineError.couldNotCreateCommandQueue
        }
        self.commandQueue = commandQueue
    }
    
    /// Clear the processed image cache
    public func clearCache() {
        processedImageCache.removeAll()
    }
    
    /// Find a processed image that has been processed with specific steps
    /// - Parameters:
    ///   - stepID: The step ID to look for
    ///   - parameters: Optional parameters that must match
    ///   - imageType: Optional image type filter
    /// - Returns: A matching ProcessedImage if found, nil otherwise
    public func findProcessedImage(
        withStep stepID: String,
        parameters: [String: String]? = nil,
        imageType: ImageType? = nil
    ) -> ProcessedImage? {
        for (_, processedImage) in processedImageCache {
            if let typeFilter = imageType, processedImage.imageType != typeFilter {
                continue
            }
            if processedImage.hasProcessingStep(stepID: stepID, parameters: parameters) {
                return processedImage
            }
        }
        return nil
    }
    
    /// Generate a cache key for a ProcessedImage based on its processing history
    private func cacheKey(for processedImage: ProcessedImage) -> String {
        var keyParts: [String] = []
        for step in processedImage.processingHistory {
            var stepKey = step.stepID
            if !step.parameters.isEmpty {
                let sortedParams = step.parameters.sorted { $0.key < $1.key }
                let paramString = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                stepKey += "[\(paramString)]"
            }
            keyParts.append(stepKey)
        }
        return keyParts.joined(separator: "->")
    }
    
    /// Add a processed image to the cache
    private func cacheProcessedImage(_ processedImage: ProcessedImage) {
        let key = cacheKey(for: processedImage)
        processedImageCache[key] = processedImage
    }
    
    /// Helper to find a processed image for a step's input requirement
    /// This allows steps to request images by processing characteristics rather than name
    private func findProcessedImageForStep(_ step: PipelineStep, inputName: String) -> ProcessedImage? {
        // Common mappings: if step requests "gaussian_blurred_image", look for images with "gaussian_blur" step
        // This is a simple heuristic - can be extended
        let stepIDMap: [String: String] = [
            "gaussian_blurred_image": "gaussian_blur",
            "blurred_image": "gaussian_blur",
            "background_subtracted_image": "background_estimation",
            "thresholded_image": "threshold",
            "eroded_image": "erosion",
            "dilated_image": "dilation"
        ]
        
        if let stepID = stepIDMap[inputName] {
            return findProcessedImage(withStep: stepID)
        }
        
        return nil
    }
    
    /// Callback type for incremental pipeline execution
    /// Called after each step completes with the step's outputs
    public typealias StepOutputCallback = (Int, PipelineStep, [String: PipelineData]) -> Void
    
    /// Execute a pipeline on a single image
    /// - Parameters:
    ///   - pipeline: The pipeline to execute
    ///   - inputs: Dictionary of input name to PipelineData
    ///   - stepOutputCallback: Optional callback called after each step completes with its outputs
    /// - Returns: Dictionary of output name to PipelineData
    /// - Throws: PipelineError if execution fails
    public func execute(
        pipeline: Pipeline,
        inputs: [String: PipelineData],
        stepOutputCallback: StepOutputCallback? = nil
    ) throws -> [String: PipelineData] {
        // Validate pipeline
        let validationErrors = pipeline.validate()
        if !validationErrors.isEmpty {
            throw PipelineError.validationFailed(validationErrors)
        }
        
        // Check required inputs
        for requiredInput in pipeline.requiredInputs {
            if inputs[requiredInput] == nil {
                throw PipelineError.missingRequiredInput(requiredInput)
            }
        }
        
        // Track available data throughout execution
        var availableData: [String: PipelineData] = inputs
        
        // Convert initial input_image to ProcessedImage if it's a FITSImage or texture
        // This ensures all steps receive ProcessedImage with proper history tracking
        if let inputImage = availableData["input_image"] {
            if inputImage.processedImage == nil {
                // Convert FITSImage or texture to ProcessedImage
                if let fitsImage = inputImage.fitsImage {
                    do {
                        let processedImage = try ProcessedImage.fromFITSImage(fitsImage, device: device)
                        availableData["input_image"] = .processedImage(processedImage)
                    } catch {
                        // If conversion fails, keep original input
                        Logger.pipeline.notice("Could not convert input_image to ProcessedImage: \(error)")
                    }
                } else if let texture = inputImage.texture {
                    let imageType = ProcessedImage.imageType(from: texture.pixelFormat)
                    let processedImage = ProcessedImage(
                        texture: texture,
                        imageType: imageType,
                        originalMinValue: 0.0,
                        originalMaxValue: 1.0,
                        processingHistory: [],
                        fitsImage: nil,
                        name: "Input Image"
                    )
                    availableData["input_image"] = .processedImage(processedImage)
                }
            }
        }
        
        // Execute each step in order
        for (stepIndex, step) in pipeline.steps.enumerated() {
            // Build inputs for this step
            var stepInputs: [String: PipelineStepInput] = [:]
            
            // Add required inputs
            for inputName in step.requiredInputs {
                guard let data = availableData[inputName] else {
                    throw PipelineError.missingRequiredInput(inputName)
                }
                stepInputs[inputName] = PipelineStepInput(name: inputName, data: data)
            }
            
            // Add optional inputs if available
            for inputName in step.optionalInputs {
                if let data = availableData[inputName] {
                    stepInputs[inputName] = PipelineStepInput(name: inputName, data: data)
                }
            }
            
            // Add pipeline context so steps can build history from the pipeline structure
            // Pass information about previous steps and their outputs
            let previousSteps = Array(pipeline.steps.prefix(stepIndex))
            
            // Collect all ProcessedImage and ProcessedTable outputs from previous steps
            // Steps can use these to build complete history
            var previousStepOutputs: [[String: Any]] = []
            for (idx, previousStep) in previousSteps.enumerated() {
                var stepOutputInfo: [String: Any] = [
                    "step_id": previousStep.id,
                    "step_name": previousStep.name,
                    "step_index": idx
                ]
                
                // Find ProcessedDataContainer, ProcessedImage, or ProcessedTable outputs from this step
                var processedOutputs: [String: Any] = [:]
                for outputName in previousStep.outputs {
                    if let data = availableData[outputName] {
                        // Check for ProcessedDataContainer first (most generic)
                        if let processedData = data.processedData {
                            processedOutputs[outputName] = [
                                "type": "processedData",
                                "dataType": String(describing: processedData.dataType),
                                "processing_history": processedData.processingHistory.map { step in
                                    [
                                        "step_id": step.stepID,
                                        "step_name": step.stepName,
                                        "parameters": step.parameters,
                                        "order": step.order
                                    ]
                                }
                            ]
                        } else if let processedImage = data.processedImage {
                            processedOutputs[outputName] = [
                                "type": "processedImage",
                                "processing_history": processedImage.processingHistory.map { step in
                                    [
                                        "step_id": step.stepID,
                                        "step_name": step.stepName,
                                        "parameters": step.parameters,
                                        "order": step.order
                                    ]
                                }
                            ]
                        } else if let processedTable = data.processedTable {
                            processedOutputs[outputName] = [
                                "type": "processedTable",
                                "processing_history": processedTable.processingHistory.map { step in
                                    [
                                        "step_id": step.stepID,
                                        "step_name": step.stepName,
                                        "parameters": step.parameters,
                                        "order": step.order
                                    ]
                                }
                            ]
                        }
                    }
                }
                
                if !processedOutputs.isEmpty {
                    stepOutputInfo["outputs"] = processedOutputs
                }
                
                previousStepOutputs.append(stepOutputInfo)
            }
            
            stepInputs["_pipeline_context"] = PipelineStepInput(
                name: "_pipeline_context",
                data: .metadata([
                    "previous_steps": previousStepOutputs,
                    "current_step_index": stepIndex,
                    "total_steps": pipeline.steps.count
                ])
            )
            
            // Execute the step
            let stepOutputs: [String: PipelineStepOutput]
            do {
                stepOutputs = try step.execute(
                    inputs: stepInputs,
                    device: device,
                    commandQueue: commandQueue
                )
            } catch let error as PipelineStepError {
                throw PipelineError.stepExecutionFailed(step.name, error)
            } catch {
                throw PipelineError.stepExecutionFailed(step.name, .executionFailed(error.localizedDescription))
            }
            
            // Add step outputs to available data
            var stepOutputData: [String: PipelineData] = [:]
            for (outputName, output) in stepOutputs {
                availableData[outputName] = output.data
                stepOutputData[outputName] = output.data
            }
            
            // Call callback with step outputs if provided
            stepOutputCallback?(stepIndex, step, stepOutputData)
        }
        
        // Return only the final outputs specified by the pipeline
        var finalOutputs: [String: PipelineData] = [:]
        for outputName in pipeline.outputs {
            if let data = availableData[outputName] {
                finalOutputs[outputName] = data
            }
        }
        
        return finalOutputs
    }
    
    /// Execute a pipeline on multiple images (batch processing)
    /// - Parameters:
    ///   - pipeline: The pipeline to execute
    ///   - imageInputs: Array of input dictionaries, one per image
    /// - Returns: Array of output dictionaries, one per image
    /// - Throws: PipelineError if execution fails
    public func executeBatch(
        pipeline: Pipeline,
        imageInputs: [[String: PipelineData]]
    ) throws -> [[String: PipelineData]] {
        var results: [[String: PipelineData]] = []
        
        for (index, inputs) in imageInputs.enumerated() {
            do {
                let outputs = try execute(pipeline: pipeline, inputs: inputs)
                results.append(outputs)
            } catch {
                throw PipelineError.stepExecutionFailed(
                    "Batch item \(index)",
                    .executionFailed(error.localizedDescription)
                )
            }
        }
        
        return results
    }
}

