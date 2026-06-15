import Foundation

/// A frame set is a collection of frames.
public struct FrameSet: ProcessData {

    /// The unique identifier for this frame set.
    public let identifier: UUID = UUID()

    /// The date and time this frame set was instantiated.
    public var instantiatedAt: Date? {
        // The frame set is instantiated when all the frames in the frame set are instantiated, 
        // and at the time the last frame was instantiated.
        if frames.allSatisfy({ $0.isInstantiated }) {
            return frames.max(by: { $0.instantiatedAt ?? Date() < $1.instantiatedAt ?? Date() })?.instantiatedAt ?? Date()
        } else {
            return nil
        }
    }

    /// Whether this frame set has been instantiated.
    public var isInstantiated: Bool { 
        return frames.allSatisfy({ $0.isInstantiated })
    }

    /// Whether this frame set is a collection. This will always return `true` for frame sets.
    /// This represents a collection of frames.
    public var isCollection: Bool { return true }

    /// The number of frames in this collection.
    public var collectionCount: Int { return frames.count }

    /// The input links for this frame set.
    /// 
    /// The input links are the links (process parameters) to which this frame set is connected.
    /// They identify the process and the parameter name into which this data is fed.
    public var inputLinks: [ProcessDataLink]

    /// The output link for this frame set.
    /// 
    /// The frame set can be produced by only one process, so there is only one output link.
    /// It is connected to the process that produces this frame set with a name reference.
    /// Named references are needed when a process produces multiple outputs and the 
    /// output data needs to be referenced by name.
    public var outputLink: ProcessDataLink?

    /// The links for this frame.
    /// 
    /// The links are the links (process parameters) to which this frame is connected.
    /// They identify the process and the parameter name into which this data is fed or taken from.
    private var links: [ProcessDataLink] = []

    /// The metadata for this frame set.
    /// 
    /// The metadata is a dictionary of frame set metadata keys and values.
    private let metadata: [FrameMetadataKey: Any]

    /// The frames in this frame set.
    public let frames: [Frame]

    /// The type of this frame set.
    public var type: FrameType {
        return metadata(for: FrameMetadataKey.type) as? FrameType ?? .unknown
    }

    /// Create a new frame set.
    /// - Parameters:
    ///   - frames: The frames in this frame set.
    ///   - outputProcess: The output process information (id, name, stepLinkID)
    ///   - inputProcesses: The input processes information (id, name, stepLinkID)
    public init(
        frames: [Frame], 
        outputProcess: (id: UUID, name: String, stepLinkID: String)?,
        inputProcesses: [(id: UUID, name: String, stepLinkID: String)]
    ) {
        self.frames = frames
        var metadata = [FrameMetadataKey: Any]()
        metadata[FrameMetadataKey.type] = FrameSet.determineFrameType(frames: frames)
        self.outputLink = outputProcess != nil ? .output(process: outputProcess!.id, link: outputProcess!.name, type: .frameSet, stepLinkID: outputProcess!.stepLinkID) : nil
        self.inputLinks = inputProcesses.map { .input(process: $0.id, link: $0.name, type: .frameSet, collectionMode: .individually, stepLinkID: $0.stepLinkID) }
        self.metadata = metadata
    }

    /// Determine the type of this frame set from the frames that belong to this frame set.
    /// 
    /// Each frame in the frame set must have the same type.
    /// If the frame set is empty, the type is `unknown`.
    /// If the frame set contains frames with different types, the type is `multiple`.
    /// - Parameter frames: The frames in this frame set.
    /// - Returns: The type of this frame set.
    private static func determineFrameType(frames: [Frame]) -> FrameType {
        if frames.isEmpty {
            return .unknown
        }
        let type = frames[0].type
        if frames.contains(where: { $0.type != type }) {
            return .multiple
        }
        return type
    }


    /// Add an input link to this frame set.
    /// 
    /// The stepLinkID will be extracted from the outputLink if available.
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
            fatalError("Output link is not set for frame set")
        }
        // Extract stepLinkID from the output link
        let stepLinkID: String
        if case .output(_, _, _, let linkStepLinkID) = outputLink {
            stepLinkID = linkStepLinkID
        } else {
            fatalError("Output link must be an output case")
        }
        self.inputLinks.append(.input(process: process, link: link, type: .frameSet, collectionMode: collectionMode, stepLinkID: stepLinkID))
    }

    /// Get the metadata for this frame set.
    /// 
    /// The function checks if the key is a valid frame metadata key and returns `nil` if it is not.
    /// - Parameter key: The key of the metadata to get.
    /// - Returns: The metadata value, or nil if the metadata does not exist.
    public func metadata(for key: any MetadataKey) -> Any? {
        guard let key = key as? FrameMetadataKey else { return nil }
        return metadata[key]
    }
}