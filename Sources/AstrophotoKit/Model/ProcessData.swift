import Foundation

/// The type of data in a pipeline (frame, frameSet, or table)
public enum DataType: String, Codable {
    /// A single frame (image)
    case frame
    /// A collection of frames
    case frameSet
    /// A table (structured data like star catalogs, measurements, etc.)
    case table
    /// A collection of tables
    case tableSet
}

/// Represents a piece of data in a pipeline.
/// 
/// Implementations are for instance frames, tables, and frame collections.
public protocol ProcessData {

    /// The unique identifier for this piece of data.
    var identifier: UUID { get  }

    /// The date and time this piece of data was instantiated.
    /// 
    /// The data may not exist yet, if the process that produces 
    /// this data has not yet been executed.
    /// 
    /// Instances of ``ProcessData`` are created when a pipeline is
    /// started. The actual data will not exist yet, except when it 
    /// is input data for the pipeline.
    var instantiatedAt: Date? { get }

    /// Whether this piece of data has been instantiated.
    /// 
    /// The data may not exist yet, if the process that produces 
    /// this data has not yet been executed.
    /// 
    /// Instances of ``ProcessData`` are created when a pipeline is
    /// started. The actual data will not exist yet, except when it 
    /// is input data for the pipeline.
    var isInstantiated: Bool { get }

    /// Whether this piece of data is a collection.
    var isCollection: Bool { get }

    /// The number of items in this collection.
    /// 
    /// This is only valid if ``isCollection`` is `true`.
    var collectionCount: Int { get }

    /// The input links for this piece of data.
    /// 
    /// The input links are the links (process parameters) to which this piece of data is connected.
    /// They identify the process and the parameter name into which this data is fed.
    var inputLinks: [ProcessDataLink] { get }

    /// The output link for this piece of data.
    /// 
    /// The data can be produced by only one process, so there is only one output link.
    /// It is connected to the process that produces this data with a name reference.
    /// Named references are needed when a process produces multiple outputs and the 
    /// output data needs to be referenced by name.
    var outputLink: ProcessDataLink? { get }

    /// Get the metadata for this piece of data.
    /// - Parameter key: The key of the metadata to get.
    /// - Returns: The metadata value, or nil if the metadata does not exist.
    func metadata(for key: any MetadataKey) -> Any?

    /// Add an input link to this piece of data.
    /// 
    /// The stepLinkID will be extracted from the outputLink if available.
    /// - Parameters:
    ///   - process: The UUID of the process
    ///   - link: The link name (parameter name)
    ///   - collectionMode: How to process collections
    mutating func addInputLink(
        process: UUID,
        link: String,
        collectionMode: CollectionMode
    )
}

/// A link to a piece of data in a process.
/// 
/// A process has a set of input and output links.
/// Each link is identified by the process identifier and the link name.
/// Input links can be either together or individually.
/// Output links are always individually.
/// Think of link names as the name of the parameter of the process in the case of an input link.
public enum ProcessDataLink {
    /// An input link to a piece of data in a process.
    /// - Parameters:
    ///   - process: The UUID of the process
    ///   - link: The link name (parameter name)
    ///   - type: The type of data
    ///   - collectionMode: How to process collections
    ///   - stepLinkID: The step link ID from the YAML `from` field (e.g., "grayscale.grayscale_frame")
    case input(process: UUID, link: String, type: DataType, collectionMode: CollectionMode, stepLinkID: String)
    /// An output link to a piece of data in a process.
    /// - Parameters:
    ///   - process: The UUID of the process
    ///   - link: The link name (output name)
    ///   - type: The type of data
    ///   - stepLinkID: The step link ID (stepIdentifier.outputName, e.g., "grayscale.grayscale_frame")
    case output(process: UUID, link: String, type: DataType, stepLinkID: String)
}

/// The mode of collection for a piece of data.
/// 
/// Collection mode is used to determine how to process a collection of data.
/// For example, if the data is a collection of frames, the collection mode can be used to determine how to process the frames.
/// * If the collection mode is `together`, all the frames will be processed together. If we have a collection of 3 frames, 
/// and the collection mode is `together`, we will have one process that will process 
/// all 3 frames together. Only one process will be created for this collection.
/// * If the collection mode is `individually`, one process will be created for each frame. If we have a collection of 3 
/// frames, and the collection mode is `individually`, we will have 3 processes, one for each frame.
public enum CollectionMode: String, Codable {
    /// All the items in the collection will be processed together.
    /// Only one process will be created for this collection.
    case together
    /// One process will be created for each individualitem in the collection.
    case individually
}
