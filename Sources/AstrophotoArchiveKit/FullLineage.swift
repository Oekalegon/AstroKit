import Foundation

/// The complete version chain for a pipeline result frame, including both
/// predecessors and successors of a nominated "current" frame.
public struct FullLineage: Sendable {
    /// All versions in the chain, ordered newest → oldest.
    public let chain: [ArchivedFrame]
    /// Index into `chain` of the frame nominated as "current."
    public let currentIndex: Int

    public var current: ArchivedFrame { chain[currentIndex] }

    /// 1-based version number of the current frame within the full chain.
    /// v1 is the oldest; v`chain.count` is the newest.
    public var currentVersionNumber: Int { chain.count - currentIndex }

    /// Total number of versions in the chain.
    public var count: Int { chain.count }
}

extension Archive {
    /// Builds the complete lineage chain containing `frame`, walking both
    /// backwards (predecessors) and forwards (successors).
    ///
    /// - Parameter frame: The "current" frame. Marked at `currentIndex` in the result.
    /// - Returns: A `FullLineage` with `chain` ordered newest → oldest.
    public func fullLineage(containing frame: ArchivedFrame) async throws -> FullLineage {
        let predecessors = try await lineage(of: frame)

        // Walk forward from `frame` to find all successors.
        var successorChain: [ArchivedFrame] = []
        var tip = frame
        var seen = Set<UUID>([frame.id])

        while true {
            let next = try await successors(of: tip)
            // If multiple successors exist, follow the one added earliest (most canonical chain).
            guard let chosen = next.filter({ !seen.contains($0.id) }).min(by: { $0.addedAt < $1.addedAt }) else { break }
            seen.insert(chosen.id)
            successorChain.append(chosen)
            tip = chosen
        }

        // successorChain is [oldest successor, ..., newest successor].
        // Reversed gives [newest successor, ..., oldest successor].
        // Combined: newest → frame → oldest.
        let chain = successorChain.reversed() + predecessors
        return FullLineage(chain: Array(chain), currentIndex: successorChain.count)
    }
}
