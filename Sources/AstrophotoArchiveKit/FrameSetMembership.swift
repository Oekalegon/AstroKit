import Foundation

/// Outcome of `Archive.addFrames(toFrameSet:frameIDs:force:)`.
public struct FrameSetAddResult: Sendable {
    /// The frame set after the addition, with refreshed aggregates.
    public let frameSet: ArchivedFrameSet
    /// Frames that were added, in input order.
    public let addedIDs: [UUID]
    /// Frames skipped because they were already members of the set.
    public let alreadyMemberIDs: [UUID]
    /// Subset of `addedIDs` that was added but marked excluded because a quality
    /// threshold from the set's creation criteria was exceeded, with the reason.
    public let excludedReasons: [UUID: String]
}

/// Outcome of `Archive.removeFrames(fromFrameSet:frameIDs:)`.
public struct FrameSetRemoveResult: Sendable {
    /// The frame set after the removal, with refreshed aggregates.
    public let frameSet: ArchivedFrameSet
    /// Frames that were removed, in input order.
    public let removedIDs: [UUID]
    /// Frames skipped because they were not members of the set.
    public let notMemberIDs: [UUID]
}
