import Foundation

/// Data input specification for a pipeline step
/// Specifies which data (frame, table, etc. from a previous step or pipeline input) this step acts upon
public struct DataInput: Codable {
    /// The data input name in the step (e.g., "input_frame", "input_table")
    public let name: String

    /// The type of data (frame, frameSet, or table)
    public let type: DataType

    /// The source of the data
    /// Format: "step_id.output_name" for step outputs, or "input_name" for pipeline inputs
    public let from: String

    /// Optional metadata restrictions to validate the input data
    /// Keys are metadata field names (e.g., "frame_type", "filter", "exposure_time", "camera")
    /// Values are restrictions that must be satisfied
    public let metadataRestrictions: [String: MetadataRestriction]?

    /// Optional description
    public let description: String?

    /// Indicates whether this input is a collection/set of items
    /// If true, the input is expected to be an array/collection of items
    public let isCollection: Bool?

    /// How to process the collection (only relevant if isCollection is true)
    /// - `together`: Process all items in the collection together (e.g., stack all frames)
    /// - `individually`: Process each item individually, creating one step instance per item
    public let collectionMode: CollectionMode?

    public init(
        name: String,
        type: DataType,
        from: String,
        metadataRestrictions: [String: MetadataRestriction]? = nil,
        description: String? = nil,
        isCollection: Bool? = nil,
        collectionMode: CollectionMode? = nil
    ) {
        self.name = name
        self.type = type
        self.from = from
        self.metadataRestrictions = metadataRestrictions
        self.description = description
        self.isCollection = isCollection
        self.collectionMode = collectionMode
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case from
        case metadataRestrictions = "metadata_restrictions"
        case description
        case isCollection = "is_collection"
        case collectionMode = "collection_mode"
    }
}
