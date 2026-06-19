import AstroKit
import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Sessions

    private static let sessionDateParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
    private static let sessionDisplayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_GB")  // stored strings must be locale-stable
        df.dateFormat = "d MMMM yyyy"
        return df
    }()
    private static let sessionISO = ISO8601DateFormatter()

    /// Finds an existing session for the given timestamp and location, or creates one.
    ///
    /// Only call this for raw light frames that have both site coordinates and a timestamp.
    /// Searches sessions within a 3 km haversine radius for the same date/night flag.
    func findOrCreateSession(timestamp: Date, latDeg: Double, lonDeg: Double) throws -> UUID {
        let observer = Observatory(longitude: lonDeg * .pi / 180, latitude: latDeg * .pi / 180)
        // Shift back 12 h so that early-morning frames (e.g. 01:30 on Jun 16) anchor to the
        // preceding noon-to-noon window (Jun 15 noon – Jun 16 noon), not the current day's.
        let anchoredDate = timestamp.addingTimeInterval(-43200)
        let rts = Sun().riseTransitSet(on: anchoredDate,
                                       at: observer, window: .night, altitude: .standardAltitudeSun)
        let isNight: Bool
        let sessionDateString: String
        let df = Self.sessionDateParser

        if let sunset = rts.set, let sunrise = rts.rise,
           timestamp >= sunset && timestamp <= sunrise {
            // Normal night: frame falls between tonight's sunset and tomorrow's sunrise.
            isNight = true
            sessionDateString = df.string(from: sunset)
        } else if rts.isAlwaysBelow {
            // Polar night: the sun never rises above the horizon during this window.
            // All frames belong to a night session, named after the date of the frame itself.
            isNight = true
            sessionDateString = df.string(from: timestamp)
        } else {
            // Day session: either the sun never sets (midnight sun) or the frame falls
            // outside the night window (shot during daytime / twilight).
            isNight = false
            sessionDateString = df.string(from: timestamp)
        }

        // Search for an existing light session on the same date at the same location.
        let selectSQL = """
            SELECT id, latitude, longitude FROM sessions
            WHERE date = ? AND is_night = ? AND frame_type = 'light'
            """
        let selectStmt = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStmt) }
        sqlite3_bind_text(selectStmt, 1, sessionDateString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(selectStmt, 2, isNight ? 1 : 0)

        var matchedID: String?
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            guard let idStr = columnText(selectStmt, 0),
                  let existingLat = columnDouble(selectStmt, 1),
                  let existingLon = columnDouble(selectStmt, 2) else { continue }
            if Self.haversineKm(lat1: latDeg, lon1: lonDeg, lat2: existingLat, lon2: existingLon) < 3.0 {
                matchedID = idStr
                break
            }
        }

        let sessionIDString: String
        let iso = Self.sessionISO
        if let existing = matchedID {
            sessionIDString = existing
        } else {
            let newID = UUID()
            let insertSQL = """
                INSERT INTO sessions (id, name, date, is_night, latitude, longitude, frame_type, frame_count, added_at)
                VALUES (?, ?, ?, ?, ?, ?, 'light', 0, ?)
                """
            let insertStmt = try prepare(insertSQL)
            defer { sqlite3_finalize(insertStmt) }
            bind(insertStmt, 1, newID.uuidString)
            bind(insertStmt, 2, Self.sessionName(for: sessionDateString))
            bind(insertStmt, 3, sessionDateString)
            sqlite3_bind_int(insertStmt, 4, isNight ? 1 : 0)
            sqlite3_bind_double(insertStmt, 5, latDeg)
            sqlite3_bind_double(insertStmt, 6, lonDeg)
            bind(insertStmt, 7, iso.string(from: Date()))
            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw ArchiveError.databaseError(dbErrorMessage())
            }
            sessionIDString = newID.uuidString
        }

        // Increment frame_count and update time bounds.
        let ts = iso.string(from: timestamp)
        let updateSQL = """
            UPDATE sessions SET
                frame_count = frame_count + 1,
                start_time  = CASE WHEN start_time IS NULL OR ? < start_time THEN ? ELSE start_time END,
                end_time    = CASE WHEN end_time   IS NULL OR ? > end_time   THEN ? ELSE end_time   END
            WHERE id = ?
            """
        let updateStmt = try prepare(updateSQL)
        defer { sqlite3_finalize(updateStmt) }
        bind(updateStmt, 1, ts); bind(updateStmt, 2, ts)
        bind(updateStmt, 3, ts); bind(updateStmt, 4, ts)
        bind(updateStmt, 5, sessionIDString)
        guard sqlite3_step(updateStmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }

        guard let uuid = UUID(uuidString: sessionIDString) else {
            throw ArchiveError.databaseError("Malformed session UUID in database: \(sessionIDString)")
        }
        return uuid
    }

    func updateSessionID(frameID: UUID, sessionID: UUID) throws {
        let stmt = try prepare("UPDATE frames SET session_id = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, sessionID.uuidString)
        bind(stmt, 2, frameID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    func allSessions() throws -> [ObservingSession] {
        let stmt = try prepare("""
            SELECT id, name, date, is_night, latitude, longitude, frame_count, start_time, end_time, added_at, frame_type
            FROM sessions
            WHERE frame_type = 'light'
               OR (frame_type IN ('dark', 'flat', 'bias') AND frame_count >= 2)
            ORDER BY date DESC, start_time DESC
            """)
        defer { sqlite3_finalize(stmt) }
        var results: [ObservingSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = rowToSession(stmt) { results.append(s) }
        }
        return results
    }

    func sessions(isNight: Bool? = nil) throws -> [ObservingSession] {
        var sql = """
            SELECT id, name, date, is_night, latitude, longitude, frame_count, start_time, end_time, added_at, frame_type
            FROM sessions WHERE frame_type = 'light'
            """
        if isNight != nil { sql += " AND is_night = ?" }
        sql += " ORDER BY date DESC, start_time DESC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let isNight { sqlite3_bind_int(stmt, 1, isNight ? 1 : 0) }
        var results: [ObservingSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = rowToSession(stmt) { results.append(s) }
        }
        return results
    }

    func calibrationSessions() throws -> [ObservingSession] {
        let stmt = try prepare("""
            SELECT id, name, date, is_night, latitude, longitude, frame_count, start_time, end_time, added_at, frame_type
            FROM sessions WHERE frame_type IN ('dark', 'flat', 'bias') AND frame_count >= 2
            ORDER BY date DESC, start_time DESC
            """)
        defer { sqlite3_finalize(stmt) }
        var results: [ObservingSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = rowToSession(stmt) { results.append(s) }
        }
        return results
    }

    func session(id: UUID) throws -> ObservingSession? {
        let stmt = try prepare("""
            SELECT id, name, date, is_night, latitude, longitude, frame_count, start_time, end_time, added_at, frame_type
            FROM sessions WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? rowToSession(stmt) : nil
    }

    func sessions(on date: Date, isNight: Bool? = nil) throws -> [ObservingSession] {
        let dateString = Self.sessionDateParser.string(from: date)
        var sql = """
            SELECT id, name, date, is_night, latitude, longitude, frame_count, start_time, end_time, added_at, frame_type
            FROM sessions WHERE date = ? AND frame_type = 'light'
            """
        if isNight != nil { sql += " AND is_night = ?" }
        sql += " ORDER BY is_night DESC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, dateString, -1, SQLITE_TRANSIENT)
        if let isNight { sqlite3_bind_int(stmt, 2, isNight ? 1 : 0) }
        var results: [ObservingSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = rowToSession(stmt) { results.append(s) }
        }
        return results
    }

    func latestSessions(limit: Int, isNight: Bool?) throws -> [ObservingSession] {
        var sql = """
            SELECT id, name, date, is_night, latitude, longitude, frame_count, start_time, end_time, added_at, frame_type
            FROM sessions WHERE frame_type = 'light'
            """
        if isNight != nil { sql += " AND is_night = ?" }
        sql += " ORDER BY date DESC, added_at DESC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let isNight {
            sqlite3_bind_int(stmt, 1, isNight ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        } else {
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }
        var results: [ObservingSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = rowToSession(stmt) { results.append(s) }
        }
        return results
    }

    func frames(inSession id: UUID) throws -> [ArchivedFrame] {
        let stmt = try prepare("""
            SELECT * FROM frames
            WHERE session_id = ?
              AND processing_level = 'raw'
            ORDER BY timestamp
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var results: [ArchivedFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let f = rowToFrame(stmt) { results.append(f) }
        }
        return results
    }

    func session(forFrame frameID: UUID) throws -> ObservingSession? {
        let stmt = try prepare("""
            SELECT s.id, s.name, s.date, s.is_night, s.latitude, s.longitude,
                   s.frame_count, s.start_time, s.end_time, s.added_at, s.frame_type
            FROM sessions s
            JOIN frames f ON f.session_id = s.id
            WHERE f.id = ?
              AND f.processing_level = 'raw'
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frameID.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToSession(stmt)
    }

    /// Assigns sessions to all raw light frames that have site coordinates and a timestamp
    /// but no session yet. Safe to call multiple times — already-assigned frames are skipped.
    func backfillSessions() throws {
        // Wrap in a transaction so the frame_count increments inside findOrCreateSession
        // and the frames.session_id assignments are atomic. Without this, an interrupted
        // backfill would leave some frames unassigned while their session's frame_count
        // was already incremented, causing over-counting on the next retry.
        try exec("BEGIN")
        do {
            let selectSQL = """
                SELECT id, timestamp, site_latitude, site_longitude FROM frames
                WHERE session_id IS NULL
                  AND site_latitude IS NOT NULL AND site_longitude IS NOT NULL
                  AND timestamp IS NOT NULL
                  AND LOWER(frame_type) = 'light'
                  AND processing_level = 'raw'
                """
            let stmt = try prepare(selectSQL)
            let iso = Self.sessionISO
            var assignments: [(frameID: String, sessionID: UUID)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let frameID   = columnText(stmt, 0),
                      let tsStr     = columnText(stmt, 1),
                      let timestamp = iso.date(from: tsStr),
                      let lat       = columnDouble(stmt, 2),
                      let lon       = columnDouble(stmt, 3) else { continue }
                let sid = try findOrCreateSession(timestamp: timestamp, latDeg: lat, lonDeg: lon)
                assignments.append((frameID, sid))
            }
            sqlite3_finalize(stmt)

            let updateStmt = try prepare("UPDATE frames SET session_id = ? WHERE id = ?")
            defer { sqlite3_finalize(updateStmt) }
            for (frameID, sessionID) in assignments {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                bind(updateStmt, 1, sessionID.uuidString)
                bind(updateStmt, 2, frameID)
                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    throw ArchiveError.databaseError(dbErrorMessage())
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func rowToSession(_ stmt: OpaquePointer?) -> ObservingSession? {
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let name  = columnText(stmt, 1),
              let dateStr = columnText(stmt, 2) else { return nil }
        guard let date = Self.sessionDateParser.date(from: dateStr) else { return nil }
        let isNight            = sqlite3_column_int(stmt, 3) != 0
        let latitude           = sqlite3_column_double(stmt, 4)
        let longitude          = sqlite3_column_double(stmt, 5)
        let frameCount         = Int(sqlite3_column_int(stmt, 6))
        let startTime          = columnText(stmt, 7).flatMap { Self.sessionISO.date(from: $0) }
        let endTime            = columnText(stmt, 8).flatMap { Self.sessionISO.date(from: $0) }
        let addedAt            = columnText(stmt, 9).flatMap { Self.sessionISO.date(from: $0) } ?? Date()
        let frameType = columnText(stmt, 10) ?? "light"
        return ObservingSession(
            id: id, name: name, date: date, isNight: isNight,
            frameType: frameType,
            latitude: latitude, longitude: longitude,
            frameCount: frameCount, startTime: startTime, endTime: endTime, addedAt: addedAt
        )
    }

    private static func sessionName(for dateString: String) -> String {
        guard let date = sessionDateParser.date(from: dateString) else { return dateString }
        return sessionDisplayFormatter.string(from: date)
    }

    /// Builds a human-readable name for a calibration session, following the same naming
    /// convention as calibration frame display names in the archive browser.
    ///
    /// Examples: "Darks -10°C on 16 June 2026", "Flats OIII on 16 June 2026", "Bias on 16 June 2026"
    private static func calibrationSessionName(
        frameType: String, dateString: String,
        temperature: Double?, filter: String?
    ) -> String {
        let dateLabel: String
        if let date = sessionDateParser.date(from: dateString) {
            dateLabel = sessionDisplayFormatter.string(from: date)
        } else {
            dateLabel = dateString
        }
        var parts: [String]
        switch frameType.lowercased() {
        case "dark":
            let tempLabel = temperature.map { String(format: "%g°C", $0) }
            parts = ["Darks", tempLabel, "on", dateLabel].compactMap { $0 }
        case "flat":
            parts = ["Flats", filter, "on", dateLabel].compactMap { $0 }
        default:
            parts = ["Bias", "on", dateLabel]
        }
        return parts.joined(separator: " ")
    }

    /// Gap threshold in seconds: if the next calibration frame starts within this many seconds
    /// of the previous frame's end (= start + exposure), they join the same session.
    private static let calibrationSessionGapSeconds: TimeInterval = 300

    /// Returns true if a frame's temperature/filter constraints are compatible with a candidate
    /// session's stored hints. Used by both `findOrCreateCalibrationSession` and
    /// `mergeAdjacentCalibrationSessions` to keep matching rules in one place.
    private func calibrationConstraintsMatch(
        frameType: String,
        frameTemp: Double?, frameFilter: String?,
        sessionTemp: Double?, sessionFilter: String?
    ) -> Bool {
        switch frameType.lowercased() {
        case "dark":
            if let t = frameTemp, let st = sessionTemp { return abs(t - st) <= 2.0 }
            return frameTemp == nil && sessionTemp == nil
        case "flat":
            return sessionFilter == frameFilter
        default:
            return true
        }
    }

    /// Finds an existing open calibration session for a new frame, or creates one.
    ///
    /// A session is "open" if the frame's start time falls within `calibrationSessionGapSeconds`
    /// of the session's current `end_time`. The session must also match on `frame_type` and,
    /// for darks, be within 2°C of the frame's temperature; for flats, match the filter exactly.
    func findOrCreateCalibrationSession(
        frameType: String,
        timestamp: Date,
        exposureTime: Double?,
        temperature: Double?,
        filter: String?
    ) throws -> UUID {
        let iso = Self.sessionISO
        let df  = Self.sessionDateParser
        let frameEnd = timestamp.addingTimeInterval(exposureTime ?? 0)
        let dateString = df.string(from: timestamp)

        // Look for an open session of the same type whose end_time is recent enough.
        // Gap = newFrame.timestamp − session.end_time must be in [0, gapSeconds]: the frame
        // must start after the session ends (≥ 0) and within the gap window (≤ gapSeconds).
        // Without the lower bound, any frame timestamped before end_time (gap < 0) would
        // also match, incorrectly joining frames from other nights.
        let selectSQL = """
            SELECT id, end_time, temperature_hint, filter_hint
            FROM sessions
            WHERE frame_type = ?
              AND end_time IS NOT NULL
              AND (julianday(?) - julianday(end_time)) * 86400 BETWEEN ? AND ?
            ORDER BY end_time DESC
            LIMIT 20
            """
        let selectStmt = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStmt) }
        bind(selectStmt, 1, frameType.lowercased())
        bind(selectStmt, 2, iso.string(from: timestamp))
        sqlite3_bind_double(selectStmt, 3, 0.0)
        sqlite3_bind_double(selectStmt, 4, Self.calibrationSessionGapSeconds)

        var matchedID: String?
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            guard let idStr = columnText(selectStmt, 0) else { continue }
            let sessionTemp   = columnDouble(selectStmt, 2)
            let sessionFilter = columnText(selectStmt, 3)
            guard calibrationConstraintsMatch(
                frameType: frameType,
                frameTemp: temperature, frameFilter: filter,
                sessionTemp: sessionTemp, sessionFilter: sessionFilter
            ) else { continue }
            matchedID = idStr
            break
        }

        if let existing = matchedID {
            // Extend the session's time window.
            let updateSQL = """
                UPDATE sessions SET
                    frame_count = frame_count + 1,
                    end_time = CASE WHEN end_time IS NULL OR ? > end_time THEN ? ELSE end_time END
                WHERE id = ?
                """
            let updateStmt = try prepare(updateSQL)
            defer { sqlite3_finalize(updateStmt) }
            let endStr = iso.string(from: frameEnd)
            bind(updateStmt, 1, endStr); bind(updateStmt, 2, endStr)
            bind(updateStmt, 3, existing)
            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw ArchiveError.databaseError(dbErrorMessage())
            }
            guard let uuid = UUID(uuidString: existing) else {
                throw ArchiveError.databaseError("Malformed session UUID: \(existing)")
            }
            try mergeAdjacentCalibrationSessions(into: uuid, frameType: frameType,
                                                 temperature: temperature, filter: filter)
            return uuid
        }

        // No matching open session — create a new one.
        let newID = UUID()
        let name  = Self.calibrationSessionName(frameType: frameType, dateString: dateString,
                                                temperature: temperature, filter: filter)
        let insertSQL = """
            INSERT INTO sessions
                (id, name, date, is_night, latitude, longitude, frame_type,
                 frame_count, start_time, end_time, added_at,
                 temperature_hint, filter_hint)
            VALUES (?, ?, ?, 0, 0, 0, ?, 1, ?, ?, ?, ?, ?)
            """
        let insertStmt = try prepare(insertSQL)
        defer { sqlite3_finalize(insertStmt) }
        bind(insertStmt, 1, newID.uuidString)
        bind(insertStmt, 2, name)
        bind(insertStmt, 3, dateString)
        bind(insertStmt, 4, frameType.lowercased())
        let startStr = iso.string(from: timestamp)
        let endStr   = iso.string(from: frameEnd)
        bind(insertStmt, 5, startStr)
        bind(insertStmt, 6, endStr)
        bind(insertStmt, 7, iso.string(from: Date()))
        if let t = temperature { sqlite3_bind_double(insertStmt, 8, t) } else { sqlite3_bind_null(insertStmt, 8) }
        if let f = filter { bind(insertStmt, 9, f) } else { sqlite3_bind_null(insertStmt, 9) }
        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        try mergeAdjacentCalibrationSessions(into: newID, frameType: frameType,
                                             temperature: temperature, filter: filter)
        return newID
    }

    /// After any session extension or creation, absorbs adjacent sessions of the same
    /// type/constraints that are adjacent to `sessionID`'s current time window. Loops
    /// until no further merge is possible.
    ///
    /// Two sessions are adjacent if either:
    /// - the candidate's `start_time` is within `gapSeconds` of our `end_time` (forward), or
    /// - the candidate's `end_time` is within `gapSeconds` of our `start_time` (backward).
    ///
    /// The backward check handles `backfillCalibrationSessions`: backfill processes frames in
    /// timestamp order, so a long-exposure bridging frame (F3) may extend S1's `end_time`
    /// past a later frame's timestamp (F2), causing F2 to create a new session S2 whose
    /// `start_time` falls inside S1's window. When `merge(into: S2)` runs, the forward
    /// check misses S1 (S1.start_time is far from S2.end_time), but the backward check
    /// catches it (S1.end_time is close to S2.start_time).
    private func mergeAdjacentCalibrationSessions(
        into sessionID: UUID,
        frameType: String,
        temperature: Double?,
        filter: String?
    ) throws {
        while true {
            // Current time window of our session (need both ends for bidirectional adjacency check).
            let tStmt = try prepare("SELECT start_time, end_time FROM sessions WHERE id = ?")
            defer { sqlite3_finalize(tStmt) }
            bind(tStmt, 1, sessionID.uuidString)
            guard sqlite3_step(tStmt) == SQLITE_ROW,
                  let startStr = columnText(tStmt, 0),
                  let endStr   = columnText(tStmt, 1) else { return }

            // Find a candidate: same type, matching temperature/filter, adjacent in either direction.
            // Forward:  other.start_time within gap of our end_time  (other starts when we end)
            // Backward: other.end_time within gap of our start_time  (other ends when we start)
            // The backward check is needed when backfillCalibrationSessions processes a frame
            // out of temporal order: the newly created session may start inside an existing
            // session's window rather than after it.
            let findSQL = """
                SELECT id, end_time, frame_count, temperature_hint, filter_hint, start_time
                FROM sessions
                WHERE frame_type = ?
                  AND id != ?
                  AND start_time IS NOT NULL
                  AND end_time IS NOT NULL
                  AND (
                    ABS((julianday(start_time) - julianday(?)) * 86400) <= ?
                    OR ABS((julianday(end_time) - julianday(?)) * 86400) <= ?
                  )
                ORDER BY MIN(
                  ABS((julianday(start_time) - julianday(?)) * 86400),
                  ABS((julianday(end_time) - julianday(?)) * 86400)
                ) ASC
                LIMIT 20
                """
            let findStmt = try prepare(findSQL)
            defer { sqlite3_finalize(findStmt) }
            bind(findStmt, 1, frameType.lowercased())
            bind(findStmt, 2, sessionID.uuidString)
            bind(findStmt, 3, endStr)                                    // forward: other.start vs our.end
            sqlite3_bind_double(findStmt, 4, Self.calibrationSessionGapSeconds)
            bind(findStmt, 5, startStr)                                  // backward: other.end vs our.start
            sqlite3_bind_double(findStmt, 6, Self.calibrationSessionGapSeconds)
            bind(findStmt, 7, endStr)                                    // ORDER BY forward
            bind(findStmt, 8, startStr)                                  // ORDER BY backward

            var srcID: String?
            var srcEndStr: String?
            var srcStartStr: String?
            var srcCount = 0
            while sqlite3_step(findStmt) == SQLITE_ROW {
                guard let idStr = columnText(findStmt, 0) else { continue }
                let adjTemp   = columnDouble(findStmt, 3)
                let adjFilter = columnText(findStmt, 4)
                guard calibrationConstraintsMatch(
                    frameType: frameType,
                    frameTemp: temperature, frameFilter: filter,
                    sessionTemp: adjTemp, sessionFilter: adjFilter
                ) else { continue }
                srcID       = idStr
                srcEndStr   = columnText(findStmt, 1)
                srcCount    = Int(sqlite3_column_int(findStmt, 2))
                srcStartStr = columnText(findStmt, 5)
                break
            }

            guard let source = srcID else { return }

            // Move, update, and delete as one atomic unit so a mid-sequence failure
            // can't leave frames moved but frame_count inflated or the source un-deleted.
            try exec("SAVEPOINT merge_calibration_session")
            do {
                // Move all frames from the source session into ours.
                let moveStmt = try prepare("UPDATE frames SET session_id = ? WHERE session_id = ?")
                defer { sqlite3_finalize(moveStmt) }
                bind(moveStmt, 1, sessionID.uuidString)
                bind(moveStmt, 2, source)
                guard sqlite3_step(moveStmt) == SQLITE_DONE else {
                    throw ArchiveError.databaseError(dbErrorMessage())
                }

                // Update frame_count, take the later end_time, and take the earlier start_time.
                let updStmt = try prepare("""
                    UPDATE sessions SET
                        frame_count = frame_count + ?,
                        end_time   = CASE WHEN ? IS NOT NULL AND (end_time   IS NULL OR ? > end_time)
                                         THEN ? ELSE end_time END,
                        start_time = CASE WHEN ? IS NOT NULL AND (start_time IS NULL OR ? < start_time)
                                         THEN ? ELSE start_time END
                    WHERE id = ?
                    """)
                defer { sqlite3_finalize(updStmt) }
                sqlite3_bind_int64(updStmt, 1, Int64(srcCount))
                bind(updStmt, 2, srcEndStr   ?? ""); bind(updStmt, 3, srcEndStr   ?? ""); bind(updStmt, 4, srcEndStr   ?? "")
                bind(updStmt, 5, srcStartStr ?? ""); bind(updStmt, 6, srcStartStr ?? ""); bind(updStmt, 7, srcStartStr ?? "")
                bind(updStmt, 8, sessionID.uuidString)
                guard sqlite3_step(updStmt) == SQLITE_DONE else {
                    throw ArchiveError.databaseError(dbErrorMessage())
                }

                // Delete the absorbed session.
                let delStmt = try prepare("DELETE FROM sessions WHERE id = ?")
                defer { sqlite3_finalize(delStmt) }
                bind(delStmt, 1, source)
                guard sqlite3_step(delStmt) == SQLITE_DONE else {
                    throw ArchiveError.databaseError(dbErrorMessage())
                }

                try exec("RELEASE SAVEPOINT merge_calibration_session")
            } catch {
                sqlite3_exec(db, "ROLLBACK TO SAVEPOINT merge_calibration_session", nil, nil, nil)
                throw error
            }
        }
    }

    /// Assigns calibration sessions to all raw calibration frames with a timestamp
    /// that have not yet been assigned to a session. Safe to call multiple times.
    func backfillCalibrationSessions() throws {
        // Collect unassigned calibration frames ordered by type, then time.
        // Read into an array first so the SELECT cursor is closed before we begin writing;
        // this avoids holding a read cursor open across the nested SAVEPOINTs that
        // mergeAdjacentCalibrationSessions uses.
        let selectSQL = """
            SELECT id, frame_type, timestamp, exposure_time, temperature, filter
            FROM frames
            WHERE session_id IS NULL
              AND timestamp IS NOT NULL
              AND LOWER(frame_type) IN ('bias', 'dark', 'flat')
              AND processing_level = 'raw'
            ORDER BY LOWER(frame_type), timestamp
            """
        let stmt = try prepare(selectSQL)
        defer { sqlite3_finalize(stmt) }

        let iso = Self.sessionISO
        typealias FrameRecord = (id: String, frameType: String, timestamp: Date,
                                 exposureTime: Double?, temperature: Double?, filter: String?)
        var records: [FrameRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let frameID   = columnText(stmt, 0),
                  let frameType = columnText(stmt, 1),
                  let tsStr     = columnText(stmt, 2),
                  let timestamp = iso.date(from: tsStr) else { continue }
            records.append((frameID, frameType, timestamp,
                            columnDouble(stmt, 3), columnDouble(stmt, 4), columnText(stmt, 5)))
        }
        guard !records.isEmpty else { return }

        // Assign session_ids inline within a single transaction. Each frame is written
        // to the DB immediately after findOrCreateCalibrationSession returns so that
        // mergeAdjacentCalibrationSessions can relocate already-assigned frames when a
        // later bridging frame triggers a session merge.
        try exec("BEGIN")
        do {
            let updateStmt = try prepare("UPDATE frames SET session_id = ? WHERE id = ?")
            defer { sqlite3_finalize(updateStmt) }
            for record in records {
                let sid = try findOrCreateCalibrationSession(
                    frameType: record.frameType, timestamp: record.timestamp,
                    exposureTime: record.exposureTime, temperature: record.temperature,
                    filter: record.filter)
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                bind(updateStmt, 1, sid.uuidString)
                bind(updateStmt, 2, record.id)
                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    throw ArchiveError.databaseError(dbErrorMessage())
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
                + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
