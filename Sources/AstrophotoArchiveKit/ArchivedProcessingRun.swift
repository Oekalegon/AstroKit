import Foundation

/// Records a pipeline execution that produced archived result frames.
///
/// A processing run captures provenance: which input frames were used,
/// which pipeline ran, and with what parameters. Each result frame stored
/// in the archive links back to its processing run so the full history
/// from raw inputs to final output is queryable.
public struct ArchivedProcessingRun: Sendable, Identifiable {
    public let id: UUID
    public let pipelineID: String
    /// Pipeline parameters serialised as String key=value pairs.
    public let parameters: [String: String]
    public let createdAt: Date
}

/// Reference to a single input frame (or file) that was consumed by a processing run.
public struct ProcessingRunInputRef: Sendable {
    /// Pipeline input name (e.g. "input_frames").
    public let inputName: String
    /// Archive frame ID, if the frame was already in the archive when the run started.
    public let frameID: UUID?
    /// Absolute path to the FITS file on disk at the time of the run.
    public let filePath: String?
    /// Position within the named input (for multi-frame inputs).
    public let position: Int

    public init(inputName: String, frameID: UUID?, filePath: String?, position: Int) {
        self.inputName = inputName
        self.frameID   = frameID
        self.filePath  = filePath
        self.position  = position
    }
}
