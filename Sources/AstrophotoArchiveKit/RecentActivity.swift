import Foundation

/// A single entry in the recent-activity feed returned by ``Archive/recentActivity(limit:)``.
public enum RecentEntry: Sendable {
    /// A proper observing session (raw light frames with site coordinates).
    /// `recency` is `startTime` of the session (the timestamp of its earliest frame),
    /// falling back to the session's named date when no frames carry a timestamp.
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
    /// Sessions are fetched directly from the sessions table and always included in the output.
    /// Non-session entries (date groups, processed frames, framesets) fill the remaining slots.
    ///
    /// - Raw light frames with a `sessionID` are suppressed from frame processing; their session
    ///   appears via the direct session query.
    /// - Raw light frames without site coordinates (no session) are grouped by UTC observation date.
    /// - Pipeline output frames (`processingRunID != nil`) are shown individually as `.frame`.
    /// - Non-raw frames and frames with no timestamp are shown individually as `.frame`.
    /// - Frame sets are shown as `.frameSet`.
    ///
    /// - Parameter limit: Maximum number of entries to return. Sessions occupy the first
    ///   `min(sessions, limit)` slots; non-session entries fill the rest. `nil` returns all.
    public func recentActivity(limit: Int? = 15) async throws -> [RecentEntry] {
        // Sessions: always query directly so they're guaranteed to appear in the feed.
        let sessionList: [ObservingSession]
        if let limit { sessionList = try await latestSessions(limit: limit) }
        else          { sessionList = try await sessions() }

        var sessionEntries: [RecentEntry] = sessionList.map { s in
            .session(s, recency: s.startTime ?? s.date)
        }

        // Reserve slots for non-session entries.
        let nonSessionSlots = limit.map { max($0 - sessionList.count, 0) }

        var nonSessionEntries: [RecentEntry] = []

        if nonSessionSlots == nil || nonSessionSlots! > 0 {
            let frameLimit = nonSessionSlots.map { max($0 * 20, 50) }
            let frames = try await recentFrames(limit: frameLimit)

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
                    if frame.sessionID != nil {
                        // Skip: this session is already in sessionEntries from the direct query.
                    } else if frame.processingRunID == nil, let ts = frame.timestamp {
                        let key = utcDateFmt.string(from: ts)
                        let existing = dateGroups[key] ?? (.distantPast, 0)
                        dateGroups[key] = (
                            recency: frame.addedAt > existing.recency ? frame.addedAt : existing.recency,
                            count:   existing.count + 1
                        )
                    } else {
                        nonSessionEntries.append(.frame(frame))
                    }
                } else {
                    nonSessionEntries.append(.frame(frame))
                }
            }

            for (key, group) in dateGroups {
                let date = utcDateFmt.date(from: key) ?? .distantPast
                nonSessionEntries.append(.dateGroup(
                    label:      labelFmt.string(from: date),
                    utcDate:    key,
                    recency:    group.recency,
                    frameCount: group.count
                ))
            }

            // frameSets(matching:) returns ORDER BY created_at DESC; prefix to non-session slots.
            let allFrameSets = try await frameSets(matching: FrameSetQuery())
            for fs in allFrameSets.prefix(nonSessionSlots ?? allFrameSets.count) {
                nonSessionEntries.append(.frameSet(fs))
            }
        }

        // Keep only the most-recent non-session entries that fit in the reserved slots.
        if let slots = nonSessionSlots {
            nonSessionEntries.sort { $0.recency > $1.recency }
            nonSessionEntries = Array(nonSessionEntries.prefix(slots))
        }

        var result = sessionEntries + nonSessionEntries
        result.sort { $0.recency > $1.recency }
        return result
    }
}
