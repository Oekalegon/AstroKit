import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Calibration sessions

    /// Gap threshold in seconds: if the next calibration frame starts within this many seconds
    /// of the previous frame's end (= start + exposure), they join the same session.
    private static let calibrationSessionGapSeconds: TimeInterval = 300

    /// Builds a human-readable name for a calibration session.
    ///
    /// Format: "{Type} [{qualifier}] - {Camera} - {Date}"
    /// Examples: "Bias - ZWO CCD ASI290MM - 16 June 2026"
    ///           "Dark -10°C - ZWO CCD ASI290MM - 16 June 2026"
    ///           "Flat OIII - ZWO CCD ASI290MM - 16 June 2026"
    ///           "Master Bias - ZWO CCD ASI290MM - 16 June 2026"
    ///           "Bias - 16 June 2026"  (no camera in FITS header)
    static func calibrationSessionName(
        frameType: String, isMaster: Bool, dateString: String,
        temperature: Double?, filter: String?, camera: String?
    ) -> String {
        let dateLabel: String
        if let date = sessionDateParser.date(from: dateString) {
            dateLabel = sessionDisplayFormatter.string(from: date)
        } else {
            dateLabel = dateString
        }

        var typeLabel: String
        switch frameType.lowercased() {
        case "bias":    typeLabel = isMaster ? "Master Bias"     : "Bias"
        case "dark":    typeLabel = isMaster ? "Master Dark"     : "Dark"
        case "flat":    typeLabel = isMaster ? "Master Flat"     : "Flat"
        case "darkflat":typeLabel = isMaster ? "Master Dark Flat": "Dark Flat"
        default:        typeLabel = frameType
        }

        switch frameType.lowercased() {
        case "dark":
            if let t = temperature { typeLabel += " \(String(format: "%g°C", t))" }
        case "flat", "darkflat":
            if let f = filter { typeLabel += " \(f)" }
        default: break
        }

        var parts = [typeLabel]
        if let cam = camera?.trimmingCharacters(in: .whitespaces), !cam.isEmpty {
            parts.append(cam)
        }
        parts.append(dateLabel)
        return parts.joined(separator: " - ")
    }

    /// Returns true if a frame's constraints are compatible with a candidate session's stored hints.
    /// Used by both `findOrCreateCalibrationSession` and `mergeAdjacentCalibrationSessions`.
    private func calibrationConstraintsMatch(
        frameType: String, frameIsMaster: Bool,
        frameTemp: Double?, frameFilter: String?, frameCamera: String?,
        sessionIsMaster: Bool, sessionTemp: Double?, sessionFilter: String?, sessionCamera: String?
    ) -> Bool {
        guard frameCamera == sessionCamera, frameIsMaster == sessionIsMaster else { return false }
        switch frameType.lowercased() {
        case "dark":
            if let t = frameTemp, let st = sessionTemp { return abs(t - st) <= 2.0 }
            return frameTemp == nil && sessionTemp == nil
        case "flat", "darkflat":
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
        isMaster: Bool = false,
        timestamp: Date,
        exposureTime: Double?,
        temperature: Double?,
        filter: String?,
        camera: String? = nil
    ) throws -> UUID {
        let df  = Self.sessionDateParser
        let frameEnd = timestamp.addingTimeInterval(exposureTime ?? 0)
        let dateString = df.string(from: timestamp)

        // Look for an open session of the same type whose end_time is recent enough.
        // Gap = newFrame.timestamp − session.end_time must be in [0, gapSeconds]: the frame
        // must start after the session ends (≥ 0) and within the gap window (≤ gapSeconds).
        // Without the lower bound, any frame timestamped before end_time (gap < 0) would
        // also match, incorrectly joining frames from other nights.
        let selectSQL = """
            SELECT id, end_time, temperature_hint, filter_hint, camera_hint, is_master
            FROM sessions
            WHERE frame_type = ?
              AND is_master = ?
              AND end_time IS NOT NULL
              AND (julianday(?) - julianday(end_time)) * 86400 BETWEEN ? AND ?
            ORDER BY end_time DESC
            LIMIT 20
            """
        let selectStmt = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStmt) }
        bind(selectStmt, 1, frameType.lowercased())
        sqlite3_bind_int(selectStmt, 2, isMaster ? 1 : 0)
        bind(selectStmt, 3, iso.string(from: timestamp))
        sqlite3_bind_double(selectStmt, 4, 0.0)
        sqlite3_bind_double(selectStmt, 5, Self.calibrationSessionGapSeconds)

        var matchedID: String?
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            guard let idStr = columnText(selectStmt, 0) else { continue }
            let sessionTemp   = columnDouble(selectStmt, 2)
            let sessionFilter = columnText(selectStmt, 3)
            let sessionCamera = columnText(selectStmt, 4)
            let sessionIsMaster = sqlite3_column_int(selectStmt, 5) != 0
            guard calibrationConstraintsMatch(
                frameType: frameType, frameIsMaster: isMaster,
                frameTemp: temperature, frameFilter: filter, frameCamera: camera,
                sessionIsMaster: sessionIsMaster, sessionTemp: sessionTemp,
                sessionFilter: sessionFilter, sessionCamera: sessionCamera
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
            try mergeAdjacentCalibrationSessions(into: uuid, frameType: frameType, isMaster: isMaster,
                                                 temperature: temperature, filter: filter, camera: camera)
            return uuid
        }

        // No matching open session — create a new one.
        let newID = UUID()
        let name  = Self.calibrationSessionName(frameType: frameType, isMaster: isMaster,
                                                dateString: dateString,
                                                temperature: temperature, filter: filter, camera: camera)
        let insertSQL = """
            INSERT INTO sessions
                (id, name, date, is_night, latitude, longitude, frame_type,
                 frame_count, start_time, end_time, added_at,
                 temperature_hint, filter_hint, camera_hint, is_master)
            VALUES (?, ?, ?, 0, 0, 0, ?, 1, ?, ?, ?, ?, ?, ?, ?)
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
        if let c = camera { bind(insertStmt, 10, c) } else { sqlite3_bind_null(insertStmt, 10) }
        sqlite3_bind_int(insertStmt, 11, isMaster ? 1 : 0)
        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        try mergeAdjacentCalibrationSessions(into: newID, frameType: frameType, isMaster: isMaster,
                                             temperature: temperature, filter: filter, camera: camera)
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
        isMaster: Bool,
        temperature: Double?,
        filter: String?,
        camera: String?
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
                SELECT id, end_time, frame_count, temperature_hint, filter_hint, start_time, camera_hint, is_master
                FROM sessions
                WHERE frame_type = ?
                  AND is_master = ?
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
            sqlite3_bind_int(findStmt, 2, isMaster ? 1 : 0)
            bind(findStmt, 3, sessionID.uuidString)
            bind(findStmt, 4, endStr)                                    // forward: other.start vs our.end
            sqlite3_bind_double(findStmt, 5, Self.calibrationSessionGapSeconds)
            bind(findStmt, 6, startStr)                                  // backward: other.end vs our.start
            sqlite3_bind_double(findStmt, 7, Self.calibrationSessionGapSeconds)
            bind(findStmt, 8, endStr)                                    // ORDER BY forward
            bind(findStmt, 9, startStr)                                  // ORDER BY backward

            var srcID: String?
            var srcEndStr: String?
            var srcStartStr: String?
            var srcCount = 0
            while sqlite3_step(findStmt) == SQLITE_ROW {
                guard let idStr = columnText(findStmt, 0) else { continue }
                let adjTemp     = columnDouble(findStmt, 3)
                let adjFilter   = columnText(findStmt, 4)
                let adjCamera   = columnText(findStmt, 6)
                let adjIsMaster = sqlite3_column_int(findStmt, 7) != 0
                guard calibrationConstraintsMatch(
                    frameType: frameType, frameIsMaster: isMaster,
                    frameTemp: temperature, frameFilter: filter, frameCamera: camera,
                    sessionIsMaster: adjIsMaster, sessionTemp: adjTemp,
                    sessionFilter: adjFilter, sessionCamera: adjCamera
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
                bind(updStmt, 2, srcEndStr);   bind(updStmt, 3, srcEndStr);   bind(updStmt, 4, srcEndStr)
                bind(updStmt, 5, srcStartStr); bind(updStmt, 6, srcStartStr); bind(updStmt, 7, srcStartStr)
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
            SELECT id, frame_type, timestamp, exposure_time, temperature, filter, camera, is_master
            FROM frames
            WHERE session_id IS NULL
              AND timestamp IS NOT NULL
              AND LOWER(frame_type) IN ('bias','dark','flat','darkflat')
            ORDER BY LOWER(frame_type), is_master, timestamp
            """
        let stmt = try prepare(selectSQL)
        defer { sqlite3_finalize(stmt) }

        typealias FrameRecord = (id: String, frameType: String, timestamp: Date,
                                 exposureTime: Double?, temperature: Double?, filter: String?,
                                 camera: String?, isMaster: Bool)
        var records: [FrameRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let frameID   = columnText(stmt, 0),
                  let frameType = columnText(stmt, 1),
                  let tsStr     = columnText(stmt, 2),
                  let timestamp = iso.date(from: tsStr) else { continue }
            records.append((frameID, frameType, timestamp,
                            columnDouble(stmt, 3), columnDouble(stmt, 4), columnText(stmt, 5),
                            columnText(stmt, 6), sqlite3_column_int(stmt, 7) != 0))
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
                    frameType: record.frameType, isMaster: record.isMaster, timestamp: record.timestamp,
                    exposureTime: record.exposureTime, temperature: record.temperature,
                    filter: record.filter, camera: record.camera)
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
}
