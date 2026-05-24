import Foundation
import Metal

/// Protocol that all pipelines must conform to
public protocol Pipeline {
    /// Unique identifier for this pipeline
    var id: String { get }
    
    /// Human-readable name for this pipeline
    var name: String { get }
    
    /// Description of what this pipeline does
    var description: String { get }
    
    /// The steps in this pipeline (in execution order)
    var steps: [PipelineStep] { get }
    
    /// Required inputs for the pipeline (from the user/external source)
    var requiredInputs: [String] { get }
    
    /// Optional inputs for the pipeline
    var optionalInputs: [String] { get }
    
    /// Outputs this pipeline produces
    var outputs: [String] { get }
    
    /// Validate that the pipeline configuration is correct
    /// - Returns: Array of validation errors (empty if valid)
    func validate() -> [String]
}

/// Base implementation of a pipeline
open class BasePipeline: Pipeline {
    public let id: String
    public let name: String
    public let description: String
    public let steps: [PipelineStep]
    public let requiredInputs: [String]
    public let optionalInputs: [String]
    public let outputs: [String]
    
    public init(
        id: String,
        name: String,
        description: String,
        steps: [PipelineStep],
        requiredInputs: [String] = [],
        optionalInputs: [String] = [],
        outputs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.requiredInputs = requiredInputs
        self.optionalInputs = optionalInputs
        
        // If outputs not specified, collect from last step
        if outputs.isEmpty && !steps.isEmpty {
            self.outputs = steps.last?.outputs ?? []
        } else {
            self.outputs = outputs
        }
    }
    
    public func validate() -> [String] {
        var errors: [String] = []
        
        // Check that steps is not empty
        if steps.isEmpty {
            errors.append("Pipeline must have at least one step")
        }
        
        // Validate each step
        for (index, step) in steps.enumerated() {
            if step.id.isEmpty {
                errors.append("Step \(index) has empty id")
            }
            if step.name.isEmpty {
                errors.append("Step \(index) has empty name")
            }
        }
        
        // Check that outputs from steps can be connected to inputs of subsequent steps
        var availableOutputs: Set<String> = Set(requiredInputs + optionalInputs)
        
        for (index, step) in steps.enumerated() {
            // Check that all required inputs are available
            for requiredInput in step.requiredInputs {
                if !availableOutputs.contains(requiredInput) {
                    errors.append("Step '\(step.name)' (index \(index)) requires input '\(requiredInput)' which is not available")
                }
            }
            
            // Add this step's outputs to available outputs
            for output in step.outputs {
                availableOutputs.insert(output)
            }
        }
        
        return errors
    }
}

/// Errors that can occur during pipeline execution
public enum PipelineError: LocalizedError {
    case validationFailed([String])
    case missingRequiredInput(String)
    case stepExecutionFailed(String, PipelineStepError)
    case metalNotAvailable
    case couldNotCreateCommandQueue
    
    public var errorDescription: String? {
        switch self {
        case .validationFailed(let errors):
            return "Pipeline validation failed:\n" + errors.joined(separator: "\n")
        case .missingRequiredInput(let name):
            return "Missing required input: \(name)"
        case .stepExecutionFailed(let stepName, let stepError):
            return "Step '\(stepName)' failed: \(stepError.localizedDescription)"
        case .metalNotAvailable:
            return "Metal is not available"
        case .couldNotCreateCommandQueue:
            return "Could not create Metal command queue"
        }
    }
}

