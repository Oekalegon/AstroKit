import Foundation
import Metal

/// Pipeline step loaded from YAML configuration
public struct PipelineStep: Codable {
    /// Unique identifier for this step instance
    public let id: String

    /// The step type/class identifier (e.g., "gaussian_blur", "threshold")
    public let type: String

    /// Human-readable name
    public let name: String?

    /// Description
    public let description: String?

    /// Data inputs: data (frames, tables, etc.) that this step acts upon
    public let dataInputs: [DataInput]

    /// Parameters: configuration values that can be adjusted between runs
    public let parameters: [ParameterSpec]

    /// Outputs: outputs that this step produces
    public let outputs: [DataOutput]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case description
        case dataInputs
        case parameters
        case outputs
    }

    public init(
        id: String,
        type: String,
        name: String? = nil,
        description: String? = nil,
        dataInputs: [DataInput] = [],
        parameters: [ParameterSpec] = [],
        outputs: [DataOutput] = []
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.description = description
        self.dataInputs = dataInputs
        self.parameters = parameters
        self.outputs = outputs
    }
}
