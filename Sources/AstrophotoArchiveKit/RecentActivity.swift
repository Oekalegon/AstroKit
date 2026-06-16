import Foundation

/// A single entry in the recent-activity feed returned by ``Archive/recentActivity(limit:)``.
public enum RecentEntry: Sendable {
    /// A proper observing session (raw light frames with site coordinates).
    /// `recency` is the `addedAt` of the most recently archived frame in the session.
    case session(ObservingSession, recency: Date)
    /// Raw light frames grouped by UTC observation date when no site coordinates are available.
    /// `utcDate` is an ISO 8601 date string ("2026-04-06"); `label` is human-readable ("6 Apr 2026").
    case dateGroup(label: String, utcDate: String, recency: Date, frameCount: Int)
    /// A non-raw frame (calibrated/stacked/stretched) or a raw frame that belongs to no
    /// session and carries no observation timestamp.
    case frame(ArchivedFrame)
    /// A frame set.
    case frameSet(ArchivedFrameSet)

    /// The timestamp used to sort the activity feed, newest first.
    public var recency: Date {
        switch self {
        case .session(_, let d):          return d
        case .dateGroup(_, _, let d, _):  return d
        case .frame(let f):               return f.addedAt
        case .frameSet(let fs):           return fs.createdAt
        }
    }
}

extension Archive {
    /// Returns a mixed recent-activity feed sorted by recency (newest first).
    ///
    /// - Raw light frames with a `sessionID` are collapsed into their ``ObservingSession``.
    /// - Raw light frames without site coordinates (no session) are grouped by UTC observation date.
    /// - Pipeline output frames (`processingRunID != nil`) are shown individually as `.frame`.
    /// - Non-raw frames and frames with no timestamp are shown individually as `.frame`.
    /// - Frame sets are shown as `.frameSet`.
    ///
    /// - Parameter limit: Maximum number of entries to return. `nil` returns all.
    public func recentActivity(limit: Int? = 15) async throws -> [RecentEntry] {
        let frameLimit = limit.map { max($0 * 20, 50) }
        let frames = try await recentFrames(limit: frameLimit)

        var entries: [RecentEntry] = []
        var sessionRecency: [UUID: Date] = [:]
        var dateGroups: [String: (recency: Date, count: Int)] = [:]

        let utcDateFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            f.timeZone = TimeZone(identifier: "UTC")!
            return f
        }()
        let labelFmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d MMM yyyy"
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()

        for frame in frames {
            if frame.processingLevel == .raw {
                if let sid = frame.sessionID {
                    let existing = sessionRecency[sid] ?? .distantPast
                    if frame.addedAt > existing { sessionRecency[sid] = frame.addedAt }
                } else if frame.processingRunID == nil, let ts = frame.timestamp {
                    let key = utcDateFmt.string(from: ts)
                    let existing = dateGroups[key] ?? (.distantPast, 0)
                    dateGroups[key] = (
                        recency: frame.addedAt > existing.recency ? frame.addedAt : existing.recency,
                        count:   existing.count + 1
                    )
                } else {
                    entries.append(.frame(frame))
                }
            } else {
                entries.append(.frame(frame))
            }
        }

        for (sid, recency) in sessionRecency {
            if let s = try await session(id: sid) {
                entries.append(.session(s, recency: recency))
            }
        }

        for (key, group) in dateGroups {
            let date = utcDateFmt.date(from: key) ?? .distantPast
            entries.append(.dateGroup(
                label:      labelFmt.string(from: date),
                utcDate:    key,
                recency:    group.recency,
                frameCount: group.count
            ))
        }

        let allFrameSets = try await frameSets(matching: FrameSetQuery())
        for fs in allFrameSets { entries.append(.frameSet(fs)) }

        entries.sort { $0.recency > $1.recency }
        if let limit { return Array(entries.prefix(limit)) }
        return entries
    }
}
