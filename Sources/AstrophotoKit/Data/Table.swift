import Foundation
import Metal
import TabularData

/// A table is a piece of data that represents a table of data.
public struct TableData: ProcessData {

    /// The unique identifier for this table.
    public let identifier: UUID = UUID()

    /// The date and time this table was instantiated.
    public private(set) var instantiatedAt: Date?

    /// Whether this table has been instantiated.
    public var isInstantiated: Bool { return instantiatedAt != nil }

    /// Whether this table is a collection. This will always return `false` for tables.
    /// This represents individual tables.
    public var isCollection: Bool { return false }

    /// The number of items in this collection.
    /// This will always return `1` for tables.
    public var collectionCount: Int { return 1 }

    /// The input links for this table.
    public var inputLinks: [ProcessDataLink]

    /// The output link for this table.
    public var outputLink: ProcessDataLink?

    /// The metadata for this table.
    private let metadata: [TableMetadataKey: Any]

    /// The actual tabular data using TabularData framework.
    /// 
    /// This is the DataFrame containing the table's data. It can be nil if the table
    /// hasn't been populated with data yet (similar to how Frame.texture can be nil).
    public var dataFrame: DataFrame? {
        didSet {
            // When the DataFrame is set, and the data for the table is available,
            // the table is instantiated. This happens when the process creating the table
            // has been completed and the table data is available.
            if dataFrame != nil {
                instantiatedAt = Date()
            } else {
                instantiatedAt = nil
            }
        }
    }

    /// Create a new table.
    /// 
    /// The table data is not necessarily instantiated during initialization, but
    /// may be provided later. At that point the table will be instantiated.
    /// 
    /// A table, or other piece of process data, is created when a pipeline is started.
    /// The actual data will not exist yet, except when it is input data for the pipeline.
    /// 
    /// - Parameters:
    ///   - dataFrame: The DataFrame containing the table data (optional)
    ///   - outputProcess: The output process link
    ///   - inputProcesses: The input process links
    public init(
        dataFrame: DataFrame? = nil,
        outputProcess: ProcessDataLink? = nil,
        inputProcesses: [ProcessDataLink] = []
    ) {
        self.instantiatedAt = dataFrame != nil ? Date() : nil
        self.dataFrame = dataFrame
        self.metadata = [:]
        self.outputLink = outputProcess
        self.inputLinks = inputProcesses
    }

    /// Instantiate this table.
    /// 
    /// This method is used to instantiate the table.
    /// 
    /// When the table is instantiated, we assume that the table data is available and ready to use.
    public mutating func instantiate() {
        self.instantiatedAt = Date()
    }

    /// Add an input link to this table.
    /// - Parameters:
    ///   - process: The UUID of the process
    ///   - link: The link name (parameter name)
    ///   - collectionMode: How to process collections
    public mutating func addInputLink(
        process: UUID,
        link: String,
        collectionMode: CollectionMode
    ) {
        guard let outputLink = outputLink else {
            fatalError("Output link is not set for table")
        }
        // Extract stepLinkID from the output link
        let stepLinkID: String
        if case .output(_, _, _, let linkStepLinkID) = outputLink {
            stepLinkID = linkStepLinkID
        } else {
            fatalError("Output link must be an output case")
        }
        self.inputLinks.append(
            .input(
                process: process,
                link: link,
                type: .table,
                collectionMode: collectionMode,
                stepLinkID: stepLinkID
            )
        )
    }

    /// Get the metadata for this table.
    /// 
    /// The function checks if the key is a valid table metadata key and returns `nil` if it is not.
    /// - Parameter key: The key of the metadata to get.
    /// - Returns: The metadata value, or nil if the metadata does not exist.
    public func metadata(for key: any MetadataKey) -> Any? {
        guard let key = key as? TableMetadataKey else { return nil }
        return metadata[key]
    }

    /// The number of rows in the table.
    /// 
    /// Returns 0 if the DataFrame is not available.
    public var rowCount: Int {
        return dataFrame?.rows.count ?? 0
    }

    /// The number of columns in the table.
    /// 
    /// Returns 0 if the DataFrame is not available.
    public var columnCount: Int {
        return dataFrame?.columns.count ?? 0
    }

    /// The column names in the table.
    /// 
    /// Returns an empty array if the DataFrame is not available.
    public var columnNames: [String] {
        return dataFrame?.columns.map { $0.name } ?? []
    }
}

/// Metadata keys for tables.
public enum TableMetadataKey: String, MetadataKey {

    /// The type of table.
    /// 
    /// The table can be a list of detected stars, a list of objects from a catalogue,
    /// a list of measurements, or a list of other data.
    case type

    /// The identifier for the metadata key.
    public var id: String {
        return "\(String(describing: Self.self)).\(rawValue)"
    }

    /// The type of the value for this metadata key.
    public var valueType: any Any.Type {
        switch self {
        case .type:
            return TableType.self
        }
    }
}

public enum TableType: String, Metadata {

    /// The table contains a list of detected stars.
    /// 
    /// The stars are represented by their coordinates and other properties,
    /// such as 
    /// * an identifier for the star in the frame,
    /// * the centroid of the star in the frame,
    /// * the major and minor axes of the image of the star,
    /// * the eccentricity of the image of the star,
    /// * the position angle of the image of the star,
    /// * and the area of the image of the star.
    /// Optionally, the table may also contain photometric properties of the star,
    /// * FWHM (Full Width at Half Maximum) of the star.
    case starsDetected

    /// The table contains a list of objects from a catalogue. These are often astrometric data.
    /// and may contain a reference to detected stars in the frame.
    case objectCatalogue

    /// The table contains frame registration results: per-frame transform and star quality statistics.
    case registration

    /// The key for this metadata value.
    /// Returns the ``TableMetadataKey.type`` key.
    public var key: any MetadataKey {
        return TableMetadataKey.type
    }

    /// The identifier for the metadata value.
    public var id: String {
        return "\(self.key).\(String(describing: Self.self)).\(rawValue)"
    }
}
