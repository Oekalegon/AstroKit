import Foundation

/// Errors that can occur during configuration parsing
public enum PipelineConfigurationError: LocalizedError {
    case invalidEncoding
    case invalidFormat(String)
    case missingRequiredField(String)
    case invalidStepReference(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Invalid encoding in configuration file"
        case .invalidFormat(let message):
            return "Invalid configuration format: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .invalidStepReference(let ref):
            return "Invalid step reference: \(ref)"
        }
    }
}
