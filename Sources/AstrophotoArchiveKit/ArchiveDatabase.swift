import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the string before the call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor ArchiveDatabase {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(url.path, &ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database = ptr else {
            throw ArchiveError.databaseError("Cannot open database at \(url.path)")
        }
        db = database
        // Enforce referential integrity so ON DELETE CASCADE/SET NULL work correctly.
        sqlite3_exec(database, "PRAGMA foreign_keys = ON", nil, nil, nil)
        // Apply migrations directly — init has exclusive access to self.
        try ArchiveDatabase.applyMigrations(db: database)
    }

    // Each entry is one schema version. Index 0 → version 1, index 1 → version 2, …
    // NEVER edit existing entries — only append new ones.
    private static let migrations: [String] = [
        // v1: initial schema
        schemaDDL,
        // v2: thumbnail blob for future autostretch support
        "ALTER TABLE frames ADD COLUMN thumbnail BLOB;",
        // v3: unique constraint on file_path (superseded by v4 — kept for schema continuity)
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_frames_filepath ON frames(file_path);",
        // v4: content-based deduplication — drop path index, add signature column and index.
        // Signature = timestamp|frameType|filter|exposureTime so re-captured files with the
        // same original path are still accepted, while true duplicate observations are rejected.
        """
        DROP INDEX IF EXISTS idx_frames_filepath;
        ALTER TABLE frames ADD COLUMN frame_signature TEXT;
        UPDATE frames SET frame_signature =
            COALESCE(timestamp, '') || '|' || LOWER(frame_type) || '|' ||
            LOWER(COALESCE(filter, '')) || '|' ||
            COALESCE(PRINTF('%.3f', exposure_time), '');
        DELETE FROM frames WHERE rowid NOT IN (
            SELECT MIN(rowid) FROM frames GROUP BY frame_signature
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_frames_signature ON frames(frame_signature);
        """,
        // v5: rejected flag — frames marked rejected are excluded from queries by default.
        """
        ALTER TABLE frames ADD COLUMN rejected INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE frames ADD COLUMN rejected_reason TEXT;
        CREATE INDEX IF NOT EXISTS idx_frames_rejected ON frames(rejected);
        """,
        // v6: frame sets — named, homogeneous collections of archived frames.
        """
        CREATE TABLE IF NOT EXISTS frame_sets (
            id               TEXT PRIMARY KEY,
            name             TEXT NOT NULL,
            frame_type       TEXT NOT NULL,
            processing_level TEXT NOT NULL DEFAULT 'raw',
            object_name      TEXT,
            filter           TEXT,
            camera           TEXT,
            exposure_time    REAL,
            temperature      REAL,
            gain             REAL,
            offset           REAL,
            width            INTEGER,
            height           INTEGER,
            created_at       TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS frame_set_members (
            frame_set_id TEXT NOT NULL REFERENCES frame_sets(id) ON DELETE CASCADE,
            frame_id     TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
            position     INTEGER NOT NULL,
            PRIMARY KEY (frame_set_id, frame_id)
        );
        CREATE INDEX IF NOT EXISTS idx_fsm_frameset ON frame_set_members(frame_set_id);
        CREATE INDEX IF NOT EXISTS idx_fsm_frame    ON frame_set_members(frame_id);
        """,
        // v7: position angle on frames; richer aggregated stats on frame_sets.
        """
        ALTER TABLE frames ADD COLUMN position_angle REAL;
        ALTER TABLE frame_sets ADD COLUMN date_from TEXT;
        ALTER TABLE frame_sets ADD COLUMN date_to TEXT;
        ALTER TABLE frame_sets ADD COLUMN temperature_mean REAL;
        ALTER TABLE frame_sets ADD COLUMN temperature_min REAL;
        ALTER TABLE frame_sets ADD COLUMN temperature_max REAL;
        ALTER TABLE frame_sets ADD COLUMN pixel_scale REAL;
        ALTER TABLE frame_sets ADD COLUMN focal_length REAL;
        ALTER TABLE frame_sets ADD COLUMN position_angle REAL;
        UPDATE frame_sets SET temperature_mean = temperature WHERE temperature IS NOT NULL;
        """,
    ]

    private static func applyMigrations(db: OpaquePointer) throws {
        // Read current schema version from SQLite's built-in version counter.
        var vstmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &vstmt, nil)
        sqlite3_step(vstmt)
        let currentVersion = Int(sqlite3_column_int(vstmt, 0))
        sqlite3_finalize(vstmt)

        for (index, sql) in migrations.enumerated() {
            let targetVersion = index + 1
            guard currentVersion < targetVersion else { continue }

            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errmsg)
                throw ArchiveError.databaseError("Migration v\(targetVersion) failed: \(msg)")
            }
            // PRAGMA user_version doesn't support ? binding; integer interpolation is safe.
            sqlite3_exec(db, "PRAGMA user_version = \(targetVersion)", nil, nil, nil)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private static let schemaDDL = """
        CREATE TABLE IF NOT EXISTS frames (
            id               TEXT PRIMARY KEY,
            file_path        TEXT NOT NULL,
            object_name      TEXT,
            ra               REAL,
            dec              REAL,
            healpix_pixel    INTEGER,
            frame_type       TEXT NOT NULL,
            filter           TEXT,
            camera           TEXT,
            focal_length     REAL,
            pixel_scale      REAL,
            temperature      REAL,
            timestamp        TEXT,
            exposure_time    REAL,
            gain             REAL,
            offset           REAL,
            width            INTEGER,
            height           INTEGER,
            bitpix           INTEGER,
            calibrated       INTEGER NOT NULL DEFAULT 0,
            stacked          INTEGER NOT NULL DEFAULT 0,
            stretched        INTEGER NOT NULL DEFAULT 0,
            processing_level TEXT NOT NULL DEFAULT 'raw',
            added_at         TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS fits_tables (
            id         TEXT PRIMARY KEY,
            file_path  TEXT NOT NULL,
            hdu_index  INTEGER NOT NULL,
            table_name TEXT,
            frame_id   TEXT REFERENCES frames(id) ON DELETE SET NULL,
            added_at   TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_frames_object   ON frames(object_name);
        CREATE INDEX IF NOT EXISTS idx_frames_type     ON frames(frame_type);
        CREATE INDEX IF NOT EXISTS idx_frames_filter   ON frames(filter);
        CREATE INDEX IF NOT EXISTS idx_frames_ts       ON frames(timestamp);
        CREATE INDEX IF NOT EXISTS idx_frames_healpix  ON frames(healpix_pixel);
        """

    // MARK: - Insert

    /// Inserts a frame, ignoring duplicates by content signature (UNIQUE index, migration v4).
    /// Returns `true` if the row was inserted, `false` if an identical observation already exists.
    @discardableResult
    func insertFrame(_ frame: ArchivedFrame) throws -> Bool {
        let sql = """
        INSERT OR IGNORE INTO frames
        (id, file_path, object_name, ra, dec, healpix_pixel, frame_type,
         filter, camera, focal_length, pixel_scale, temperature, timestamp,
         exposure_time, gain, offset, width, height, bitpix,
         calibrated, stacked, stretched, processing_level, added_at, thumbnail,
         frame_signature, rejected, rejected_reason, position_angle)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1,  frame.id.uuidString)
        bind(stmt, 2,  frame.filePath)
        bind(stmt, 3,  frame.objectName)
        bind(stmt, 4,  frame.ra)
        bind(stmt, 5,  frame.dec)
        bind(stmt, 6,  frame.healpixPixel)
        bind(stmt, 7,  frame.frameType)
        bind(stmt, 8,  frame.filter)
        bind(stmt, 9,  frame.camera)
        bind(stmt, 10, frame.focalLength)
        bind(stmt, 11, frame.pixelScale)
        bind(stmt, 12, frame.temperature)
        bind(stmt, 13, frame.timestamp.map { iso.string(from: $0) })
        bind(stmt, 14, frame.exposureTime)
        bind(stmt, 15, frame.gain)
        bind(stmt, 16, frame.offset)
        bind(stmt, 17, frame.width.map { Int64($0) })
        bind(stmt, 18, frame.height.map { Int64($0) })
        bind(stmt, 19, frame.bitpix.map { Int64($0) })
        sqlite3_bind_int(stmt, 20, frame.calibrated ? 1 : 0)
        sqlite3_bind_int(stmt, 21, frame.stacked    ? 1 : 0)
        sqlite3_bind_int(stmt, 22, frame.stretched  ? 1 : 0)
        bind(stmt, 23, frame.processingLevel.rawValue)
        bind(stmt, 24, iso.string(from: frame.addedAt))
        bind(stmt, 25, frame.thumbnail)
        bind(stmt, 26, ArchiveDatabase.frameSignature(
            timestamp: frame.timestamp,
            frameType: frame.frameType,
            filter: frame.filter,
            exposureTime: frame.exposureTime
        ))
        sqlite3_bind_int(stmt, 27, frame.rejected ? 1 : 0)
        bind(stmt, 28, frame.rejectedReason)
        bind(stmt, 29, frame.positionAngle)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        return sqlite3_changes(db) > 0
    }

    // Stable string key used for content-based deduplication.
    // Components: ISO8601 timestamp (or ""), lowercased frame type,
    // lowercased filter (or ""), exposure formatted to 3 decimal places (or "").
    static func frameSignature(
        timestamp: Date?,
        frameType: String,
        filter: String?,
        exposureTime: Double?
    ) -> String {
        let iso = ISO8601DateFormatter()
        let ts = timestamp.map { iso.string(from: $0) } ?? ""
        let ft = frameType.lowercased()
        let fi = (filter ?? "").lowercased()
        let ex = exposureTime.map { String(format: "%.3f", $0) } ?? ""
        return "\(ts)|\(ft)|\(fi)|\(ex)"
    }

    func insertTable(_ table: ArchivedTable) throws {
        let sql = """
        INSERT OR REPLACE INTO fits_tables (id, file_path, hdu_index, table_name, frame_id, added_at)
        VALUES (?,?,?,?,?,?)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()
        bind(stmt, 1, table.id.uuidString)
        bind(stmt, 2, table.filePath)
        sqlite3_bind_int(stmt, 3, Int32(table.hduIndex))
        bind(stmt, 4, table.tableName)
        bind(stmt, 5, table.frameID?.uuidString)
        bind(stmt, 6, iso.string(from: table.addedAt))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    // MARK: - Query

    func queryFrames(_ query: FrameQuery, healpixPixels: [Int64]?) throws -> [ArchivedFrame] {
        var conditions: [String] = []
        var bindings: [Any] = []

        if let name = query.objectName {
            conditions.append("object_name LIKE ?")
            bindings.append("%\(name)%")
        }
        if let cam = query.camera {
            conditions.append("camera = ?")
            bindings.append(cam)
        }
        if let pixels = healpixPixels, !pixels.isEmpty {
            conditions.append("healpix_pixel IN (\(pixels.map { _ in "?" }.joined(separator: ",")))")
            for p in pixels { bindings.append(p) }
        }
        if let types = query.frameTypes, !types.isEmpty {
            conditions.append("frame_type IN (\(types.map { _ in "?" }.joined(separator: ",")))")
            for t in types { bindings.append(t) }
        }
        if let filters = query.filters, !filters.isEmpty {
            conditions.append("filter IN (\(filters.map { _ in "?" }.joined(separator: ",")))")
            for f in filters { bindings.append(f) }
        }
        if let range = query.dateRange {
            let iso = ISO8601DateFormatter()
            conditions.append("timestamp >= ?"); bindings.append(iso.string(from: range.start))
            conditions.append("timestamp <= ?"); bindings.append(iso.string(from: range.end))
        }
        if let tr = query.temperatureRange {
            conditions.append("temperature >= ?"); bindings.append(tr.lowerBound)
            conditions.append("temperature <= ?"); bindings.append(tr.upperBound)
        }
        if let cal = query.calibrated {
            conditions.append("calibrated = ?"); bindings.append(cal ? 1 : 0)
        }
        if let stk = query.stacked {
            conditions.append("stacked = ?"); bindings.append(stk ? 1 : 0)
        }
        if let str = query.stretched {
            conditions.append("stretched = ?"); bindings.append(str ? 1 : 0)
        }
        if let lvl = query.processingLevel {
            conditions.append("processing_level = ?"); bindings.append(lvl.rawValue)
        }
        switch query.rejectionFilter {
        case .excludeRejected: conditions.append("rejected = 0")
        case .onlyRejected:    conditions.append("rejected = 1")
        case .includeAll:      break
        }

        var sql = "SELECT * FROM frames"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY timestamp DESC"
        if let limit = query.limit { sql += " LIMIT \(limit)" }

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

        var results: [ArchivedFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let f = rowToFrame(stmt) { results.append(f) }
        }
        return results
    }

    func frameByID(_ id: UUID) throws -> ArchivedFrame? {
        let stmt = try prepare("SELECT * FROM frames WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrame(stmt) : nil
    }

    func frameFilePath(id: UUID) throws -> String? {
        let stmt = try prepare("SELECT file_path FROM frames WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    func updateRejected(id: UUID, rejected: Bool, reason: String?) throws {
        let stmt = try prepare("UPDATE frames SET rejected = ?, rejected_reason = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, rejected ? 1 : 0)
        bind(stmt, 2, reason)
        bind(stmt, 3, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    func deleteFrame(id: UUID) throws {
        let stmt = try prepare("DELETE FROM frames WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    // MARK: - Frame sets

    // Shared SELECT columns for both list and single-item queries.
    // Indices: 0–13 = v6 core, 14–21 = v7 extras, 22 = frame_count.
    private static let frameSetSelectSQL = """
        SELECT fs.id, fs.name, fs.frame_type, fs.processing_level,
               fs.object_name, fs.filter, fs.camera, fs.exposure_time, fs.temperature,
               fs.gain, fs.offset, fs.width, fs.height, fs.created_at,
               fs.date_from, fs.date_to,
               fs.temperature_mean, fs.temperature_min, fs.temperature_max,
               fs.pixel_scale, fs.focal_length, fs.position_angle,
               COUNT(fsm.frame_id) AS frame_count
        FROM frame_sets fs
        LEFT JOIN frame_set_members fsm ON fsm.frame_set_id = fs.id
        """

    func insertFrameSet(_ fs: ArchivedFrameSet, frameIDs: [UUID]) throws {
        let iso = ISO8601DateFormatter()
        try exec("BEGIN")
        let sql = """
        INSERT INTO frame_sets
        (id, name, frame_type, processing_level, object_name, filter, camera,
         exposure_time, temperature, gain, offset, width, height, created_at,
         date_from, date_to, temperature_mean, temperature_min, temperature_max,
         pixel_scale, focal_length, position_angle)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        bind(stmt, 8,  fs.exposureTime)
        bind(stmt, 9,  fs.temperatureMean)   // legacy `temperature` column = mean
        bind(stmt, 10, fs.gain)
        bind(stmt, 11, fs.offset)
        bind(stmt, 12, fs.width.map { Int64($0) })
        bind(stmt, 13, fs.height.map { Int64($0) })
        bind(stmt, 14, iso.string(from: fs.createdAt))
        bind(stmt, 15, fs.dateFrom.map { iso.string(from: $0) })
        bind(stmt, 16, fs.dateTo.map   { iso.string(from: $0) })
        bind(stmt, 17, fs.temperatureMean)
        bind(stmt, 18, fs.temperatureMin)
        bind(stmt, 19, fs.temperatureMax)
        bind(stmt, 20, fs.pixelScale)
        bind(stmt, 21, fs.focalLength)
        bind(stmt, 22, fs.positionAngle)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw ArchiveError.databaseError(dbErrorMessage())
        }

        let memberSQL = "INSERT INTO frame_set_members (frame_set_id, frame_id, position) VALUES (?,?,?)"
        for (position, frameID) in frameIDs.enumerated() {
            let mstmt = try prepare(memberSQL)
            defer { sqlite3_finalize(mstmt) }
            bind(mstmt, 1, fs.id.uuidString)
            bind(mstmt, 2, frameID.uuidString)
            sqlite3_bind_int(mstmt, 3, Int32(position))
            guard sqlite3_step(mstmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw ArchiveError.databaseError(dbErrorMessage())
            }
        }
        try exec("COMMIT")
    }

    func queryFrameSets() throws -> [ArchivedFrameSet] {
        let sql = ArchiveDatabase.frameSetSelectSQL + " GROUP BY fs.id ORDER BY fs.created_at DESC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
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

    func frameIDsForSet(_ id: UUID) throws -> [UUID] {
        let stmt = try prepare(
            "SELECT frame_id FROM frame_set_members WHERE frame_set_id = ? ORDER BY position"
        )
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

    func deleteFrameSet(id: UUID) throws {
        let stmt = try prepare("DELETE FROM frame_sets WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    private func rowToFrameSet(_ stmt: OpaquePointer?) -> ArchivedFrameSet? {
        // Column map — see frameSetSelectSQL for ordering.
        // 0–13: v6 core, 14–21: v7 extras, 22: frame_count
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let name = columnText(stmt, 1),
              let frameType = columnText(stmt, 2),
              let levelStr = columnText(stmt, 3),
              let createdAtStr = columnText(stmt, 13)
        else { return nil }

        let iso = ISO8601DateFormatter()
        let processingLevel = ProcessingLevel(rawValue: levelStr) ?? .raw
        let createdAt = iso.date(from: createdAtStr) ?? Date()
        // temperature_mean (col 16) preferred; fall back to legacy temperature (col 8) for pre-v7 rows.
        let tempMean = columnDouble(stmt, 16) ?? columnDouble(stmt, 8)

        return ArchivedFrameSet(
            id: id,
            name: name,
            frameType: frameType,
            processingLevel: processingLevel,
            createdAt: createdAt,
            frameCount: Int(sqlite3_column_int(stmt, 22)),
            objectName:   columnText(stmt, 4),
            filter:       columnText(stmt, 5),
            camera:       columnText(stmt, 6),
            exposureTime: columnDouble(stmt, 7),
            gain:         columnDouble(stmt, 9),
            offset:       columnDouble(stmt, 10),
            width:  sqlite3_column_type(stmt, 11) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 11)) : nil,
            height: sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 12)) : nil,
            pixelScale:    columnDouble(stmt, 19),
            focalLength:   columnDouble(stmt, 20),
            positionAngle: columnDouble(stmt, 21),
            dateFrom: columnText(stmt, 14).flatMap { iso.date(from: $0) },
            dateTo:   columnText(stmt, 15).flatMap { iso.date(from: $0) },
            temperatureMean: tempMean,
            temperatureMin:  columnDouble(stmt, 17),
            temperatureMax:  columnDouble(stmt, 18)
        )
    }

    // MARK: - Statistics

    func statistics(archiveRoot: URL) throws -> ArchiveStatistics {
        let objectCount = try scalarInt("SELECT COUNT(DISTINCT object_name) FROM frames WHERE object_name IS NOT NULL") ?? 0
        let frameCount  = try scalarInt("SELECT COUNT(*) FROM frames") ?? 0

        var byType: [String: Int] = [:]
        for row in try rows("SELECT frame_type, COUNT(*) FROM frames GROUP BY frame_type") {
            if let t = row[0] as? String, let n = row[1] as? Int { byType[t] = n }
        }

        var byTypeAndFilter: [String: [String: Int]] = [:]
        for row in try rows("SELECT frame_type, COALESCE(filter,'none'), COUNT(*) FROM frames GROUP BY frame_type, filter") {
            if let t = row[0] as? String, let f = row[1] as? String, let n = row[2] as? Int {
                byTypeAndFilter[t, default: [:]][f] = n
            }
        }

        var processedByObject: [String: Int] = [:]
        let sql = "SELECT object_name, COUNT(*) FROM frames WHERE object_name IS NOT NULL AND processing_level != 'raw' GROUP BY object_name"
        for row in try rows(sql) {
            if let obj = row[0] as? String, let n = row[1] as? Int { processedByObject[obj] = n }
        }

        return ArchiveStatistics(
            objectCount: objectCount,
            frameCount: frameCount,
            frameCountByType: byType,
            frameCountByTypeAndFilter: byTypeAndFilter,
            processedFramesByObject: processedByObject,
            usedBytes: diskUsage(at: archiveRoot),
            availableBytes: availableSpace(at: archiveRoot)
        )
    }

    func listObjects() throws -> [(name: String, count: Int)] {
        try rows("SELECT object_name, COUNT(*) FROM frames WHERE object_name IS NOT NULL GROUP BY object_name ORDER BY object_name")
            .compactMap { row -> (String, Int)? in
                guard let n = row[0] as? String, let c = row[1] as? Int else { return nil }
                return (n, c)
            }
    }

    // MARK: - Row mapping

    private func rowToFrame(_ stmt: OpaquePointer?) -> ArchivedFrame? {
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let filePath = columnText(stmt, 1)
        else { return nil }

        let iso = ISO8601DateFormatter()
        return ArchivedFrame(
            id: id,
            filePath: filePath,
            objectName: columnText(stmt, 2),
            ra:  columnDouble(stmt, 3),
            dec: columnDouble(stmt, 4),
            healpixPixel: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_int64(stmt, 5) : nil,
            frameType: columnText(stmt, 6) ?? "unknown",
            filter:    columnText(stmt, 7),
            camera:    columnText(stmt, 8),
            focalLength:  columnDouble(stmt, 9),
            pixelScale:   columnDouble(stmt, 10),
            temperature:  columnDouble(stmt, 11),
            timestamp:    columnText(stmt, 12).flatMap { iso.date(from: $0) },
            exposureTime: columnDouble(stmt, 13),
            gain:   columnDouble(stmt, 14),
            offset: columnDouble(stmt, 15),
            width:  sqlite3_column_type(stmt, 16) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 16)) : nil,
            height: sqlite3_column_type(stmt, 17) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 17)) : nil,
            bitpix: sqlite3_column_type(stmt, 18) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 18)) : nil,
            calibrated: sqlite3_column_int(stmt, 19) != 0,
            stacked:    sqlite3_column_int(stmt, 20) != 0,
            stretched:  sqlite3_column_int(stmt, 21) != 0,
            processingLevel: ProcessingLevel(rawValue: columnText(stmt, 22) ?? "raw") ?? .raw,
            addedAt: columnText(stmt, 23).flatMap { iso.date(from: $0) } ?? Date(),
            thumbnail: columnBlob(stmt, 24),
            rejected: sqlite3_column_int(stmt, 26) != 0,
            rejectedReason: columnText(stmt, 27),
            positionAngle: columnDouble(stmt, 28)
        )
    }

    // MARK: - SQLite helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        return stmt
    }

    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errmsg)
            throw ArchiveError.databaseError(msg)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func rows(_ sql: String) throws -> [[Any?]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var result: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_count(stmt))
            var row: [Any?] = []
            for col in 0..<n {
                switch sqlite3_column_type(stmt, Int32(col)) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int(stmt, Int32(col))))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(stmt, Int32(col)))
                case SQLITE_TEXT:    row.append(String(cString: sqlite3_column_text(stmt, Int32(col))!))
                default:             row.append(nil)
                }
            }
            result.append(row)
        }
        return result
    }

    private func dbErrorMessage() -> String {
        guard let db else { return "Database not open" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Bind helpers

    private func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String) {
        sqlite3_bind_text(stmt, pos, value, -1, SQLITE_TRANSIENT)
    }
    private func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String?) {
        if let v = value { sqlite3_bind_text(stmt, pos, v, -1, SQLITE_TRANSIENT) }
        else              { sqlite3_bind_null(stmt, pos) }
    }
    private func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, pos, v) }
        else             { sqlite3_bind_null(stmt, pos) }
    }
    private func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int64?) {
        if let v = value { sqlite3_bind_int64(stmt, pos, v) }
        else             { sqlite3_bind_null(stmt, pos) }
    }
    private func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Data?) {
        guard let v = value else { sqlite3_bind_null(stmt, pos); return }
        _ = v.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, pos, ptr.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
        }
    }

    // MARK: - Column helpers

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }
    private func columnDouble(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }
    private func columnBlob(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    // MARK: - Disk helpers

    private func diskUsage(at url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func availableSpace(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return 0 }
        return Int64(capacity)
    }
}
