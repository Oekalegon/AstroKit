import Foundation

/// Errors that can occur during processor execution
public enum ProcessorExecutionError: LocalizedError {
    case processorNotFound(String)
    case missingRequiredInput(String)
    case invalidInputType(String, expected: String)
    case executionFailed(String)
    case metalNotAvailable
    case couldNotCreateResource(String)

    /// Whether this error is fatal and should stop the entire pipeline
    public var isFatal: Bool {
        switch self {
        case .processorNotFound, .metalNotAvailable, .couldNotCreateResource:
            return true
        case .missingRequiredInput, .invalidInputType, .executionFailed:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .processorNotFound(let type):
            return "Processor not found for type: \(type)"
        case .missingRequiredInput(let name):
            return "Missing required input: \(name)"
        case .invalidInputType(let name, let expected):
            return "Invalid input type for '\(name)': expected \(expected)"
        case .executionFailed(let message):
            return "Processor execution failed: \(message)"
        case .metalNotAvailable:
            return "Metal is not available"
        case .couldNotCreateResource(let message):
            return "Could not create resource: \(message)"
        }
    }
}


