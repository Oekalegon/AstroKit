import Foundation

/// A frame in the context of a specific frame set, carrying the per-set exclusion state.
///
/// Unlike `ArchivedFrame.rejected`, the `excluded` flag is specific to one frame set:
/// the same frame can be active in one set and excluded from another.
/// Pipelines that process a frame set receive only the active (non-excluded) members.
public struct FrameSetMember: Sendable {
    public let frame: ArchivedFrame
    /// True when the frame is skipped during processing of this frame set.
    public var excluded: Bool
    /// Human-readable reason for the exclusion, or nil.
    public var excludedReason: String?

    public init(frame: ArchivedFrame, excluded: Bool = false, excludedReason: String? = nil) {
        self.frame = frame
        self.excluded = excluded
        self.excludedReason = excludedReason
    }
}
