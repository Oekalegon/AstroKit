import Foundation

/// Output specification for a pipeline step
/// Defines an output that a step produces, including metadata
public struct DataOutput: Codable {
    /// The output name
    public let name: String

    /// The type of data (frame, frameSet, or table)
    public let type: DataType

    /// Description of what this output represents
    public let description: String?

    /// Optional metadata to add or override
    /// Steps may add their own metadata during execution, and config metadata will be merged/overridden
    public let metadata: [String: AnyCodable]?

    public init(
        name: String,
        type: DataType,
        description: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.metadata = metadata?.mapValues { AnyCodable($0) }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case description
        case metadata
    }

    /// Get metadata as dictionary of Any
    public func getMetadata() -> [String: Any] {
        guard let metadata = metadata else { return [:] }
        return metadata.mapValues { $0.value }
    }
}
