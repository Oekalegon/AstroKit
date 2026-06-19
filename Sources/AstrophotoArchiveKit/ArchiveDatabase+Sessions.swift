import AstroKit
import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Sessions

    // Promoted to internal so ArchiveDatabase+CalibrationSessions.swift can access them.
    static let sessionDateParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
    static let sessionDisplayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_GB")  // stored strings must be locale-stable
        df.dateFormat = "d MMMM yyyy"
        return df
    }()

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
        sqlite3_bind_text(selectStmt, 1, sessionDateString, -1, ArchiveDatabase.sqliteTransient)
        sqlite3_bind_int(selectStmt, 2, isNight ? 1 : 0)

        var matchedID: String?
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            guard let idStr = columnText(selectStmt, 0),
                  let existingLat = columnDouble(selectStmt, 1),
                  let existingLon = columnDouble(selectStmt, 2) else { continue }
            if Self.haversineKm(lat1Deg: latDeg, lon1Deg: lonDeg, lat2Deg: existingLat, lon2Deg: existingLon) < 3.0 {
                matchedID = idStr
                break
            }
        }

        let sessionIDString: String
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
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, ArchiveDatabase.sqliteTransient)
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
        sqlite3_bind_text(stmt, 1, dateString, -1, ArchiveDatabase.sqliteTransient)
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
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, ArchiveDatabase.sqliteTransient)
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
        sqlite3_bind_text(stmt, 1, frameID.uuidString, -1, ArchiveDatabase.sqliteTransient)
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
        let isNight    = sqlite3_column_int(stmt, 3) != 0
        let latitude   = sqlite3_column_double(stmt, 4)
        let longitude  = sqlite3_column_double(stmt, 5)
        let frameCount = Int(sqlite3_column_int(stmt, 6))
        let startTime  = columnText(stmt, 7).flatMap { iso.date(from: $0) }
        let endTime    = columnText(stmt, 8).flatMap { iso.date(from: $0) }
        let addedAt    = columnText(stmt, 9).flatMap { iso.date(from: $0) } ?? Date()
        let frameType  = columnText(stmt, 10) ?? "light"
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

    private static func haversineKm(lat1Deg: Double, lon1Deg: Double, lat2Deg: Double, lon2Deg: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2Deg - lat1Deg) * .pi / 180
        let dLon = (lon2Deg - lon1Deg) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
                + cos(lat1Deg * .pi / 180) * cos(lat2Deg * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
