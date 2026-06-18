import Foundation

/// Declares what a pipeline produces when it finishes.
/// - `.default`: pipeline emits output frames and/or tables that may be archived or saved to disk.
/// - `.metadata`: pipeline only updates metadata on its input frames (e.g. quality metrics); it
///   produces no new files and nothing should be archived or written to an output path.
public enum PipelineResultType: String, Codable {
    case `default`
    case metadata
}
