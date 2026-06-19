import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Frame sets

    // Shared SELECT columns for both list and single-item queries.
    // Indices: 0–13 = v6 core, 14–21 = v7 extras,
    //          22–26 = v19 quality aggregates, 27 = frame_count, 28 = excluded_count,
    //          29–30 = v24 telescope/site, 31 = v27 criteria.
    static let frameSetSelectSQL = """
        SELECT fs.id, fs.name, fs.frame_type, fs.processing_level,
               fs.object_name, fs.filter, fs.camera, fs.exposure_time, fs.temperature,
               fs.gain, fs.offset, fs.width, fs.height, fs.created_at,
               fs.date_from, fs.date_to,
               fs.temperature_mean, fs.temperature_min, fs.temperature_max,
               fs.pixel_scale, fs.focal_length, fs.position_angle,
               fs.median_star_count, fs.median_fwhm, fs.median_eccentricity,
               fs.median_background_noise, fs.median_background_noise_electrons,
               COUNT(fsm.frame_id) AS frame_count,
               SUM(CASE WHEN fsm.excluded = 1 THEN 1 ELSE 0 END) AS excluded_count,
               fs.telescope, fs.site, fs.criteria
        FROM frame_sets fs
        LEFT JOIN frame_set_members fsm ON fsm.frame_set_id = fs.id
        """

    func insertFrameSet(
        _ fs: ArchivedFrameSet,
        frameIDs: [UUID],
        excludedIDs: Set<UUID> = [],
        excludedReasons: [UUID: String] = [:]
    ) throws {
        try exec("BEGIN")
        do {
            let sql = """
            INSERT INTO frame_sets
            (id, name, frame_type, processing_level, object_name, filter, camera,
             telescope, site,
             exposure_time, temperature, gain, offset, width, height, created_at,
             date_from, date_to, temperature_mean, temperature_min, temperature_max,
             pixel_scale, focal_length, position_angle,
             median_star_count, median_fwhm, median_eccentricity,
             median_background_noise, median_background_noise_electrons, criteria)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1,  fs.id.uuidString)
            bind(stmt, 2,  fs.name)
            bind(stmt, 3,  fs.frameType)
            bind(stmt, 4,  fs.processingLevel.rawValue)
            bind(stmt, 5,  fs.objectName)
            bind(stmt, 6,  fs.filter)
            bind(stmt, 7,  fs.camera)
            bind(stmt, 8,  fs.telescope)
            bind(stmt, 9,  fs.site)
            bind(stmt, 10, fs.exposureTime)
            bind(stmt, 11, fs.temperatureMean)   // legacy `temperature` column = mean
            bind(stmt, 12, fs.gain)
            bind(stmt, 13, fs.offset)
            bind(stmt, 14, fs.width.map { Int64($0) })
            bind(stmt, 15, fs.height.map { Int64($0) })
            bind(stmt, 16, iso.string(from: fs.createdAt))
            bind(stmt, 17, fs.dateFrom.map { iso.string(from: $0) })
            bind(stmt, 18, fs.dateTo.map   { iso.string(from: $0) })
            bind(stmt, 19, fs.temperatureMean)
            bind(stmt, 20, fs.temperatureMin)
            bind(stmt, 21, fs.temperatureMax)
            bind(stmt, 22, fs.pixelScale)
            bind(stmt, 23, fs.focalLength)
            bind(stmt, 24, fs.positionAngle)
            bind(stmt, 25, fs.medianStarCount)
            bind(stmt, 26, fs.medianFWHM)
            bind(stmt, 27, fs.medianEccentricity)
            bind(stmt, 28, fs.medianBackgroundNoise)
            bind(stmt, 29, fs.medianBackgroundNoiseElectrons)
            bind(stmt, 30, ArchiveDatabase.encodeCriteria(fs.criteria))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ArchiveError.databaseError(dbErrorMessage())
            }
            try insertMembers(
                setID: fs.id.uuidString,
                frameIDs: frameIDs,
                startPosition: 0,
                excludedIDs: excludedIDs,
                excludedReasons: excludedReasons
            )
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func queryFrameSets() throws -> [ArchivedFrameSet] {
        try queryFrameSets(matching: FrameSetQuery())
    }

    func queryFrameSets(matching query: FrameSetQuery) throws -> [ArchivedFrameSet] {
        var conditions: [String] = []
        var bindings: [Any] = []

        if let name = query.name {
            conditions.append("fs.name LIKE ?")
            bindings.append("%\(name)%")
        }
        if let obj = query.objectName {
            conditions.append("fs.object_name LIKE ?")
            bindings.append("%\(obj)%")
        }
        if let types = query.frameTypes, !types.isEmpty {
            conditions.append("fs.frame_type IN (\(types.map { _ in "?" }.joined(separator: ",")))")
            for t in types { bindings.append(t) }
        }
        if let filters = query.filters, !filters.isEmpty {
            let normalized = filters.map { ArchiveDatabase.normalizeFilterComponent($0) }
            // A frameset's filter column may be a single name or a comma-separated list
            // (when created with --force). Match if any requested filter appears in the field.
            let filterClauses = normalized.map { _ in
                "(LOWER(fs.filter) = ? OR LOWER(fs.filter) LIKE ? OR LOWER(fs.filter) LIKE ? OR LOWER(fs.filter) LIKE ?)"
            }.joined(separator: " OR ")
            conditions.append("(\(filterClauses))")
            for f in normalized {
                bindings.append(f)
                bindings.append("\(f),%")
                bindings.append("%,\(f)")
                bindings.append("%,\(f),%")
            }
        }
        if let lvl = query.processingLevel {
            conditions.append("fs.processing_level = ?")
            bindings.append(lvl.rawValue)
        }
        if let cam = query.camera {
            conditions.append("fs.camera = ?")
            bindings.append(cam)
        }
        if let scope = query.telescope {
            conditions.append("fs.telescope = ?")
            bindings.append(scope)
        }
        if let s = query.site {
            conditions.append("fs.site = ?")
            bindings.append(s)
        }
        if let range = query.dateRange {
            let iso = ISO8601DateFormatter()
            // Overlap: frameset spans [date_from, date_to]; query spans [start, end].
            // Overlap iff date_from <= end AND date_to >= start.
            // NULLs in date_from/date_to mean the frameset has no timestamp data — include it.
            conditions.append("(fs.date_from IS NULL OR fs.date_from <= ?)")
            bindings.append(iso.string(from: range.end))
            conditions.append("(fs.date_to IS NULL OR fs.date_to >= ?)")
            bindings.append(iso.string(from: range.start))
        }

        var sql = ArchiveDatabase.frameSetSelectSQL
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " GROUP BY fs.id ORDER BY fs.created_at DESC"

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bindings.enumerated() {
            let pos = Int32(i + 1)
            switch value {
            case let s as String: sqlite3_bind_text(stmt, pos, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(stmt, pos, d)
            case let n as Int:    sqlite3_bind_int(stmt, pos, Int32(n))
            case let n as Int64:  sqlite3_bind_int64(stmt, pos, n)
            default: break
            }
        }

        var results: [ArchivedFrameSet] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let fs = rowToFrameSet(stmt) { results.append(fs) }
        }
        return results
    }

    func frameSetByID(_ id: UUID) throws -> ArchivedFrameSet? {
        let sql = ArchiveDatabase.frameSetSelectSQL + " WHERE fs.id = ? GROUP BY fs.id"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrameSet(stmt) : nil
    }

    func frameIDsForSet(_ id: UUID, activeOnly: Bool = false) throws -> [UUID] {
        let sql = activeOnly
            ? "SELECT frame_id FROM frame_set_members WHERE frame_set_id = ? AND excluded = 0 ORDER BY position"
            : "SELECT frame_id FROM frame_set_members WHERE frame_set_id = ? ORDER BY position"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = columnText(stmt, 0), let uuid = UUID(uuidString: s) {
                ids.append(uuid)
            }
        }
        return ids
    }

    /// Returns all member frames of a frame set together with their per-set exclusion state.
    func membersForSet(_ id: UUID) throws -> [(frameID: UUID, excluded: Bool, excludedReason: String?)] {
        let stmt = try prepare(
            "SELECT frame_id, excluded, excluded_reason FROM frame_set_members WHERE frame_set_id = ? ORDER BY position"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var result: [(UUID, Bool, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let s = columnText(stmt, 0), let uuid = UUID(uuidString: s) else { continue }
            let excluded = sqlite3_column_int(stmt, 1) != 0
            let reason   = columnText(stmt, 2)
            result.append((uuid, excluded, reason))
        }
        return result
    }

    /// Sets or clears the excluded flag for a single frame within a frame set.
    func updateMemberExcluded(
        frameSetID: UUID,
        frameID: UUID,
        excluded: Bool,
        reason: String?
    ) throws {
        let stmt = try prepare(
            "UPDATE frame_set_members SET excluded = ?, excluded_reason = ? WHERE frame_set_id = ? AND frame_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, excluded ? 1 : 0)
        bind(stmt, 2, reason)
        bind(stmt, 3, frameSetID.uuidString)
        bind(stmt, 4, frameID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// Appends frames to an existing frame set, positioned after the current members.
    /// Callers are responsible for validation — this performs the raw inserts only.
    func addFrameSetMembers(
        setID: UUID,
        frameIDs: [UUID],
        excludedIDs: Set<UUID> = [],
        excludedReasons: [UUID: String] = [:]
    ) throws {
        guard !frameIDs.isEmpty else { return }

        // BEGIN IMMEDIATE so the MAX(position) read and all inserts are atomic.
        try exec("BEGIN IMMEDIATE")
        do {
            let posStmt = try prepare(
                "SELECT COALESCE(MAX(position), -1) FROM frame_set_members WHERE frame_set_id = ?"
            )
            defer { sqlite3_finalize(posStmt) }
            bind(posStmt, 1, setID.uuidString)
            guard sqlite3_step(posStmt) == SQLITE_ROW else {
                throw ArchiveError.databaseError(dbErrorMessage())
            }
            let nextPosition = Int(sqlite3_column_int(posStmt, 0)) + 1
            try insertMembers(
                setID: setID.uuidString,
                frameIDs: frameIDs,
                startPosition: nextPosition,
                excludedIDs: excludedIDs,
                excludedReasons: excludedReasons
            )
            try exec("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Removes the given frames from a frame set. Frames not in the set are ignored.
    /// Returns the number of membership rows actually deleted.
    func removeFrameSetMembers(setID: UUID, frameIDs: [UUID]) throws -> Int {
        guard !frameIDs.isEmpty else { return 0 }
        // Chunk to stay well under SQLite's default 999-variable limit (setID takes one slot).
        let chunkSize = 500
        var totalDeleted = 0
        for chunk in stride(from: 0, to: frameIDs.count, by: chunkSize).map({ frameIDs[$0..<min($0 + chunkSize, frameIDs.count)] }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let stmt = try prepare(
                "DELETE FROM frame_set_members WHERE frame_set_id = ? AND frame_id IN (\(placeholders))"
            )
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, setID.uuidString)
            for (i, fid) in chunk.enumerated() {
                bind(stmt, Int32(i + 2), fid.uuidString)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ArchiveError.databaseError(dbErrorMessage())
            }
            totalDeleted += Int(sqlite3_changes(db))
        }
        return totalDeleted
    }

    /// Rewrites the stored aggregate columns (shared scalars, date span, temperature
    /// statistics, and quality medians) of a frame set from the given value.
    /// Identity fields (id, name, frame_type, processing_level, created_at, criteria)
    /// are not touched.
    func updateFrameSetAggregates(_ fs: ArchivedFrameSet) throws {
        let sql = """
        UPDATE frame_sets SET
            object_name = ?, filter = ?, camera = ?, telescope = ?, site = ?,
            exposure_time = ?, temperature = ?, gain = ?, offset = ?,
            width = ?, height = ?,
            date_from = ?, date_to = ?,
            temperature_mean = ?, temperature_min = ?, temperature_max = ?,
            pixel_scale = ?, focal_length = ?, position_angle = ?,
            median_star_count = ?, median_fwhm = ?, median_eccentricity = ?,
            median_background_noise = ?, median_background_noise_electrons = ?
        WHERE id = ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1,  fs.objectName)
        bind(stmt, 2,  fs.filter)
        bind(stmt, 3,  fs.camera)
        bind(stmt, 4,  fs.telescope)
        bind(stmt, 5,  fs.site)
        bind(stmt, 6,  fs.exposureTime)
        bind(stmt, 7,  fs.temperatureMean)   // legacy `temperature` column = mean
        bind(stmt, 8,  fs.gain)
        bind(stmt, 9,  fs.offset)
        bind(stmt, 10, fs.width.map { Int64($0) })
        bind(stmt, 11, fs.height.map { Int64($0) })
        bind(stmt, 12, fs.dateFrom.map { iso.string(from: $0) })
        bind(stmt, 13, fs.dateTo.map   { iso.string(from: $0) })
        bind(stmt, 14, fs.temperatureMean)
        bind(stmt, 15, fs.temperatureMin)
        bind(stmt, 16, fs.temperatureMax)
        bind(stmt, 17, fs.pixelScale)
        bind(stmt, 18, fs.focalLength)
        bind(stmt, 19, fs.positionAngle)
        bind(stmt, 20, fs.medianStarCount)
        bind(stmt, 21, fs.medianFWHM)
        bind(stmt, 22, fs.medianEccentricity)
        bind(stmt, 23, fs.medianBackgroundNoise)
        bind(stmt, 24, fs.medianBackgroundNoiseElectrons)
        bind(stmt, 25, fs.id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// Returns all frameset IDs that contain the given frame.
    func frameSetIDsForFrame(_ frameID: UUID) throws -> [UUID] {
        let stmt = try prepare(
            "SELECT frame_set_id FROM frame_set_members WHERE frame_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, frameID.uuidString, -1, SQLITE_TRANSIENT)
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = columnText(stmt, 0), let uuid = UUID(uuidString: s) {
                ids.append(uuid)
            }
        }
        return ids
    }

    func deleteFrameSet(id: UUID) throws {
        let stmt = try prepare("DELETE FROM frame_sets WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    func updateFrameSetQuality(
        id: UUID,
        medianStarCount: Double?,
        medianFWHM: Double?,
        medianEccentricity: Double?,
        medianBackgroundNoise: Double?,
        medianBackgroundNoiseElectrons: Double?
    ) throws {
        var setClauses: [String] = []
        var values: [Double] = []
        if let v = medianStarCount               { setClauses.append("median_star_count = ?");                   values.append(v) }
        if let v = medianFWHM                    { setClauses.append("median_fwhm = ?");                        values.append(v) }
        if let v = medianEccentricity            { setClauses.append("median_eccentricity = ?");                values.append(v) }
        if let v = medianBackgroundNoise         { setClauses.append("median_background_noise = ?");            values.append(v) }
        if let v = medianBackgroundNoiseElectrons { setClauses.append("median_background_noise_electrons = ?"); values.append(v) }
        guard !setClauses.isEmpty else { return }

        let sql = "UPDATE frame_sets SET \(setClauses.joined(separator: ", ")) WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() { sqlite3_bind_double(stmt, Int32(i + 1), v) }
        bind(stmt, Int32(values.count + 1), id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    // MARK: - Frame set member helpers

    /// Inserts membership rows for `frameIDs` starting at `startPosition`.
    /// Must be called inside an open transaction.
    private func insertMembers(
        setID: String,
        frameIDs: [UUID],
        startPosition: Int,
        excludedIDs: Set<UUID> = [],
        excludedReasons: [UUID: String] = [:]
    ) throws {
        guard !frameIDs.isEmpty else { return }
        let stmt = try prepare("""
            INSERT INTO frame_set_members (frame_set_id, frame_id, position, excluded, excluded_reason)
            VALUES (?,?,?,?,?)
            """)
        defer { sqlite3_finalize(stmt) }
        for (offset, frameID) in frameIDs.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(stmt, 1, setID)
            bind(stmt, 2, frameID.uuidString)
            sqlite3_bind_int(stmt, 3, Int32(startPosition + offset))
            sqlite3_bind_int(stmt, 4, excludedIDs.contains(frameID) ? 1 : 0)
            bind(stmt, 5, excludedReasons[frameID])
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ArchiveError.databaseError(dbErrorMessage())
            }
        }
    }

}
