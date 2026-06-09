import AstrophotoKit
import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the string before the call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor ArchiveDatabase {
    private var db: OpaquePointer?
    let archiveRootPath: String

    init(url: URL, archiveRootPath: String) throws {
        self.archiveRootPath = archiveRootPath
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
        // Normalize any legacy absolute paths to archive-root-relative paths.
        ArchiveDatabase.normalizeFilePaths(db: database, archiveRootPath: archiveRootPath)
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
        // v8: processing runs — provenance for pipeline-produced frames.
        """
        CREATE TABLE IF NOT EXISTS processing_runs (
            id          TEXT PRIMARY KEY,
            pipeline_id TEXT NOT NULL,
            parameters  TEXT,
            created_at  TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS processing_run_inputs (
            run_id     TEXT NOT NULL REFERENCES processing_runs(id) ON DELETE CASCADE,
            input_name TEXT NOT NULL,
            frame_id   TEXT REFERENCES frames(id) ON DELETE SET NULL,
            file_path  TEXT,
            position   INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_run_inputs_run   ON processing_run_inputs(run_id);
        CREATE INDEX IF NOT EXISTS idx_run_inputs_frame ON processing_run_inputs(frame_id);
        ALTER TABLE frames ADD COLUMN processing_run_id TEXT REFERENCES processing_runs(id) ON DELETE SET NULL;
        CREATE INDEX IF NOT EXISTS idx_frames_run ON frames(processing_run_id);
        """,
        // v9: session date range for stacked frames (DATE-BEG / DATE-END).
        """
        ALTER TABLE frames ADD COLUMN session_beg TEXT;
        ALTER TABLE frames ADD COLUMN session_end TEXT;
        """,
        // v10: temperature range for stacked frames.
        """
        ALTER TABLE frames ADD COLUMN temperature_min REAL;
        ALTER TABLE frames ADD COLUMN temperature_max REAL;
        """,
        // v11: normalize filter display name from "Ha" (and variants) to "Hɑ" everywhere.
        // Also recomputes frame_signature so deduplication remains consistent for Hɑ frames.
        """
        UPDATE frames SET
            filter = 'Hɑ',
            frame_signature = COALESCE(timestamp, '') || '|' || LOWER(frame_type) || '|hɑ|' || COALESCE(PRINTF('%.3f', exposure_time), '')
        WHERE LOWER(filter) IN ('ha', 'h-alpha', 'h_alpha', 'halpha', 'h alpha');
        UPDATE frame_sets SET filter = 'Hɑ'
        WHERE LOWER(filter) IN ('ha', 'h-alpha', 'h_alpha', 'halpha', 'h alpha');
        """,
        // v12: quality metrics for light frames — star count, median FWHM, background noise.
        // These are populated by analysis pipelines (star_detection, background_estimation)
        // or read from FITS headers (NSTARS, MEDFWHM, BACKNOIS) on import.
        """
        ALTER TABLE frames ADD COLUMN star_count INTEGER;
        ALTER TABLE frames ADD COLUMN median_fwhm REAL;
        ALTER TABLE frames ADD COLUMN background_noise REAL;
        """,
        // v13: mean star eccentricity — populated by star_detection / frame_registration_quad pipelines
        // or read from the FITS header MEDECCEN on import.
        "ALTER TABLE frames ADD COLUMN median_eccentricity REAL;",
        // v14: saturated star count (light frames) and hot pixel count (calibration frames).
        // Populated by frame_quality and calibration_quality pipelines respectively, or read
        // from FITS headers NSATSTAR / NHOTPIX.
        // Note: background_noise semantics change with this release — frames analysed by the new
        // frame_quality / calibration_quality pipelines store ADU values; older frames retain the
        // legacy normalised 0–1 value.
        """
        ALTER TABLE frames ADD COLUMN saturated_star_count INTEGER;
        ALTER TABLE frames ADD COLUMN hot_pixel_count INTEGER;
        """,
        // v15: EGAIN — separate electron conversion factor (e⁻/ADU) from the camera gain setting.
        // GAIN (stored in the existing `gain` column) is the camera's gain *setting*, a dimensionless
        // number (e.g. 0–300 for ZWO cameras). EGAIN is the physical factor that converts raw ADU
        // to electrons: electrons = (adu - offset) × egain.
        "ALTER TABLE frames ADD COLUMN egain REAL;",
        // v16: camera_profiles — auto-learned GAIN-setting → EGAIN mapping per camera.
        // Populated automatically during archiving when a frame carries INSTRUME + GAIN + EGAIN.
        // Can also be populated manually for cameras that do not write EGAIN in their FITS headers.
        """
        CREATE TABLE IF NOT EXISTS camera_profiles (
            camera_name  TEXT NOT NULL,
            gain_setting REAL NOT NULL,
            egain        REAL NOT NULL,
            updated_at   TEXT NOT NULL,
            PRIMARY KEY (camera_name, gain_setting)
        );
        """,
        // v17: background_noise_electrons — background level / noise sigma in electrons.
        // Derived from (background_noise - offset) × egain; only populated when EGAIN is available.
        // Cross-camera comparable (independent of gain setting and bit depth).
        // `offset` is the camera bias pedestal in ADU; defaults to 0 when absent.
        // Backfill existing rows where both background_noise and egain are known.
        """
        ALTER TABLE frames ADD COLUMN background_noise_electrons REAL;
        UPDATE frames SET background_noise_electrons = (background_noise - COALESCE(offset, 0)) * egain
        WHERE background_noise IS NOT NULL AND egain IS NOT NULL;
        """,
        // v18: per-frameset exclusion flag — a frame can be excluded from one set while
        // remaining active in another. Unlike the global `rejected` flag, this is specific
        // to a single frame_set_members row and can be toggled by the user or set
        // automatically when quality metrics exceed pipeline thresholds.
        """
        ALTER TABLE frame_set_members ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE frame_set_members ADD COLUMN excluded_reason TEXT;
        CREATE INDEX IF NOT EXISTS idx_fsm_excluded ON frame_set_members(frame_set_id, excluded);
        """,
        // v19: quality aggregates on frame_sets — medians over active member frames.
        // Populated on frameset creation and refreshed by `ap-archive frameset quality`.
        """
        ALTER TABLE frame_sets ADD COLUMN median_star_count REAL;
        ALTER TABLE frame_sets ADD COLUMN median_fwhm REAL;
        ALTER TABLE frame_sets ADD COLUMN median_eccentricity REAL;
        ALTER TABLE frame_sets ADD COLUMN median_background_noise REAL;
        ALTER TABLE frame_sets ADD COLUMN median_background_noise_electrons REAL;
        """,
        // v20: normalize bare "H" filter to "Hɑ" — same pattern as v11 for other Ha aliases.
        // Uses REPLACE(frame_signature, '|h|', '|hɑ|') rather than recomputing the whole
        // signature, so it works regardless of whether fileDate or timestamp was used when
        // the frame was originally ingested.
        // Archives that contain both an 'H' frame and an 'Hɑ' frame for the same observation
        // (ingested twice with different filter spellings) have a true duplicate. The 'H' copy
        // is deleted first to avoid a UNIQUE constraint violation on the signature update.
        """
        DELETE FROM frames
        WHERE LOWER(filter) = 'h'
          AND EXISTS (
            SELECT 1 FROM frames AS dup
            WHERE dup.frame_signature = REPLACE(frames.frame_signature, '|h|', '|hɑ|')
          );
        UPDATE frames SET
            filter = 'Hɑ',
            frame_signature = REPLACE(frame_signature, '|h|', '|hɑ|')
        WHERE LOWER(filter) = 'h';
        UPDATE frame_sets SET filter = 'Hɑ'
        WHERE LOWER(filter) = 'h';
        """,
        // v21: per-frame display stretch settings — JSON-encoded StretchSettings.
        // Stores the normalized [0,1] black/white points the user last applied and saved.
        // NULL means identity stretch (full range). Persisted here rather than in FITS
        // headers so the original file is never modified.
        "ALTER TABLE frames ADD COLUMN stretch_settings TEXT;",
        // v22: slider positions within the saved stretch, stored independently of the
        // normalization bounds. Both are normalized to [0,1] of the full data range so
        // they can be restored regardless of bit depth or BZERO/BSCALE scaling.
        // NULL means use defaults (0 for black, 1 for white).
        """
        ALTER TABLE frames ADD COLUMN slider_black_norm REAL;
        ALTER TABLE frames ADD COLUMN slider_white_norm REAL;
        """,
        // v23: telescope and site on frames — propagated from input frames into stacked results.
        // telescope = FITS TELESCOP keyword; site = FITS OBSERVAT keyword.
        """
        ALTER TABLE frames ADD COLUMN telescope TEXT;
        ALTER TABLE frames ADD COLUMN site       TEXT;
        """,
        // v24: telescope and site on frame_sets — mirrors v23 on frames so framesets can be
        // searched and filtered by telescope/site.
        """
        ALTER TABLE frame_sets ADD COLUMN telescope TEXT;
        ALTER TABLE frame_sets ADD COLUMN site       TEXT;
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

    // Strips the archive root prefix from any file_path rows that still carry an absolute path.
    // Idempotent — rows already stored as relative paths are unaffected.
    private static func normalizeFilePaths(db: OpaquePointer, archiveRootPath: String) {
        let prefix = archiveRootPath + "/"
        let sql = """
            UPDATE frames
               SET file_path = SUBSTR(file_path, ?)
             WHERE file_path LIKE ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        // SUBSTR start position is 1-based; skip the root + trailing slash.
        sqlite3_bind_int(stmt, 1, Int32(prefix.utf8.count + 1))
        sqlite3_bind_text(stmt, 2, prefix + "%", -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)

        // Same normalization for fits_tables.
        let tableSQL = """
            UPDATE fits_tables
               SET file_path = SUBSTR(file_path, ?)
             WHERE file_path LIKE ?
            """
        var tstmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, tableSQL, -1, &tstmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(tstmt) }
        sqlite3_bind_int(tstmt, 1, Int32(prefix.utf8.count + 1))
        sqlite3_bind_text(tstmt, 2, prefix + "%", -1, SQLITE_TRANSIENT)
        sqlite3_step(tstmt)
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
         frame_signature, rejected, rejected_reason, position_angle, processing_run_id,
         session_beg, session_end, temperature_min, temperature_max,
         star_count, median_fwhm, background_noise, median_eccentricity,
         saturated_star_count, hot_pixel_count, egain, background_noise_electrons,
         telescope, site)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
            fileDate: frame.fileDate,
            frameType: frame.frameType,
            filter: frame.filter,
            exposureTime: frame.exposureTime
        ))
        sqlite3_bind_int(stmt, 27, frame.rejected ? 1 : 0)
        bind(stmt, 28, frame.rejectedReason)
        bind(stmt, 29, frame.positionAngle)
        bind(stmt, 30, frame.processingRunID?.uuidString)
        bind(stmt, 31, frame.sessionBeg.map { iso.string(from: $0) })
        bind(stmt, 32, frame.sessionEnd.map { iso.string(from: $0) })
        bind(stmt, 33, frame.temperatureMin)
        bind(stmt, 34, frame.temperatureMax)
        bind(stmt, 35, frame.starCount.map { Int64($0) })
        bind(stmt, 36, frame.medianFWHM)
        bind(stmt, 37, frame.backgroundNoise)
        bind(stmt, 38, frame.medianEccentricity)
        bind(stmt, 39, frame.saturatedStarCount.map { Int64($0) })
        bind(stmt, 40, frame.hotPixelCount.map { Int64($0) })
        bind(stmt, 41, frame.egain)
        bind(stmt, 42, frame.backgroundNoiseElectrons)
        bind(stmt, 43, frame.telescope)
        bind(stmt, 44, frame.site)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        return sqlite3_changes(db) > 0
    }

    // Canonical lowercase token used in frame signatures and filter queries.
    // Maps all Hɑ aliases to the same token so deduplication is consistent across
    // frames ingested before and after the "Ha" → "Hɑ" rename.
    static func normalizeFilterComponent(_ filter: String) -> String {
        switch filter.lowercased() {
        case "h", "ha", "h-alpha", "h_alpha", "halpha", "h alpha", "hα", "hɑ":
            return "hɑ"
        default:
            return filter.lowercased()
        }
    }

    /// Canonical display name for a filter string read from a FITS header.
    /// Normalises all Hɑ aliases to the proper Unicode display form "Hɑ".
    /// Returns `nil` for nil input; passes other filter strings through unchanged.
    static func canonicalFilterName(_ filter: String?) -> String? {
        guard let filter = filter else { return nil }
        switch filter.lowercased() {
        case "h", "ha", "h-alpha", "h_alpha", "halpha", "h alpha", "hα", "hɑ":
            return "Hɑ"
        default:
            return filter
        }
    }

    // Stable string key used for content-based deduplication.
    // Components: fileDate (DATE header → DATE-OBS → filesystem, or ""), lowercased frame type,
    // normalised filter (or ""), exposure formatted to 3 decimal places (or "").
    static func frameSignature(
        fileDate: Date?,
        frameType: String,
        filter: String?,
        exposureTime: Double?
    ) -> String {
        let iso = ISO8601DateFormatter()
        let ts = fileDate.map { iso.string(from: $0) } ?? ""
        let ft = frameType.lowercased()
        let fi = normalizeFilterComponent(filter ?? "")
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
            let normalized = filters.map { ArchiveDatabase.normalizeFilterComponent($0) }
            conditions.append("LOWER(filter) IN (\(normalized.map { _ in "?" }.joined(separator: ",")))")
            for f in normalized { bindings.append(f) }
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
        // Quality filters: NULL rows are implicitly excluded by the comparison (NULL <= x is NULL → false).
        if let maxFWHM = query.maxFWHM {
            conditions.append("median_fwhm <= ?"); bindings.append(maxFWHM)
        }
        if let minStars = query.minStarCount {
            conditions.append("star_count >= ?"); bindings.append(Int64(minStars))
        }
        if let maxNoise = query.maxBackgroundNoise {
            conditions.append("background_noise <= ?"); bindings.append(maxNoise)
        }
        if let maxEcc = query.maxEccentricity {
            conditions.append("median_eccentricity <= ?"); bindings.append(maxEcc)
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

    /// Updates quality metrics on a frame. Only non-nil values are written;
    /// passing `nil` for a metric leaves the existing DB value unchanged.
    /// Updates observation metadata fields for a single frame.
    /// Only non-nil arguments are written; existing values are never overwritten with NULL.
    func updateObservationMetadata(
        id: UUID,
        objectName: String?,
        camera: String?,
        telescope: String?,
        site: String?
    ) throws {
        var setClauses: [String] = []
        var values: [String] = []
        if let v = objectName { setClauses.append("object_name = ?"); values.append(v) }
        if let v = camera     { setClauses.append("camera = ?");      values.append(v) }
        if let v = telescope  { setClauses.append("telescope = ?");   values.append(v) }
        if let v = site       { setClauses.append("site = ?");        values.append(v) }
        guard !setClauses.isEmpty else { return }

        let sql = "UPDATE frames SET \(setClauses.joined(separator: ", ")) WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, v) in values.enumerated() { bind(stmt, Int32(i + 1), v) }
        bind(stmt, Int32(values.count + 1), id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    func updateFrameQuality(
        id: UUID,
        starCount: Int?,
        medianFWHM: Double?,
        backgroundNoise: Double?,
        medianEccentricity: Double? = nil,
        saturatedStarCount: Int? = nil,
        hotPixelCount: Int? = nil,
        backgroundNoiseElectrons: Double? = nil
    ) throws {
        // Build SET clause dynamically so we never overwrite a metric with NULL.
        var setClauses: [String] = []
        var values: [Any] = []
        if let v = starCount                 { setClauses.append("star_count = ?");                    values.append(Int64(v)) }
        if let v = medianFWHM                { setClauses.append("median_fwhm = ?");                   values.append(v) }
        if let v = backgroundNoise           { setClauses.append("background_noise = ?");              values.append(v) }
        if let v = medianEccentricity        { setClauses.append("median_eccentricity = ?");           values.append(v) }
        if let v = saturatedStarCount        { setClauses.append("saturated_star_count = ?");          values.append(Int64(v)) }
        if let v = hotPixelCount             { setClauses.append("hot_pixel_count = ?");               values.append(Int64(v)) }
        if let v = backgroundNoiseElectrons  { setClauses.append("background_noise_electrons = ?");    values.append(v) }
        guard !setClauses.isEmpty else { return }

        let sql = "UPDATE frames SET \(setClauses.joined(separator: ", ")) WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        for (i, value) in values.enumerated() {
            let pos = Int32(i + 1)
            switch value {
            case let n as Int64:  sqlite3_bind_int64(stmt, pos, n)
            case let d as Double: sqlite3_bind_double(stmt, pos, d)
            default: break
            }
        }
        bind(stmt, Int32(values.count + 1), id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// All three columns are always written together in a single UPDATE.
    /// Pass the current slider norms alongside any normalization change, or they will be
    /// cleared to NULL. `nil` for any parameter writes NULL (i.e. "not set / use default").
    func updateStretchSettings(
        id: UUID,
        settings: StretchSettings?,
        sliderBlackNorm: Float? = nil,
        sliderWhiteNorm: Float? = nil
    ) throws {
        let json: String?
        if let settings {
            let data = try JSONEncoder().encode(settings)
            json = String(data: data, encoding: .utf8)
        } else {
            json = nil
        }
        let stmt = try prepare(
            "UPDATE frames SET stretch_settings = ?, slider_black_norm = ?, slider_white_norm = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, json)
        bind(stmt, 2, sliderBlackNorm.map { Double($0) })
        bind(stmt, 3, sliderWhiteNorm.map { Double($0) })
        bind(stmt, 4, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
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
    // Indices: 0–13 = v6 core, 14–21 = v7 extras,
    //          22–26 = v19 quality aggregates, 27 = frame_count, 28 = excluded_count,
    //          29–30 = v24 telescope/site.
    private static let frameSetSelectSQL = """
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
               fs.telescope, fs.site
        FROM frame_sets fs
        LEFT JOIN frame_set_members fsm ON fsm.frame_set_id = fs.id
        """

    func insertFrameSet(
        _ fs: ArchivedFrameSet,
        frameIDs: [UUID],
        excludedIDs: Set<UUID> = [],
        excludedReasons: [UUID: String] = [:]
    ) throws {
        let iso = ISO8601DateFormatter()
        try exec("BEGIN")
        let sql = """
        INSERT INTO frame_sets
        (id, name, frame_type, processing_level, object_name, filter, camera,
         telescope, site,
         exposure_time, temperature, gain, offset, width, height, created_at,
         date_from, date_to, temperature_mean, temperature_min, temperature_max,
         pixel_scale, focal_length, position_angle,
         median_star_count, median_fwhm, median_eccentricity,
         median_background_noise, median_background_noise_electrons)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw ArchiveError.databaseError(dbErrorMessage())
        }

        let memberSQL = """
            INSERT INTO frame_set_members (frame_set_id, frame_id, position, excluded, excluded_reason)
            VALUES (?,?,?,?,?)
            """
        for (position, frameID) in frameIDs.enumerated() {
            let mstmt = try prepare(memberSQL)
            defer { sqlite3_finalize(mstmt) }
            bind(mstmt, 1, fs.id.uuidString)
            bind(mstmt, 2, frameID.uuidString)
            sqlite3_bind_int(mstmt, 3, Int32(position))
            sqlite3_bind_int(mstmt, 4, excludedIDs.contains(frameID) ? 1 : 0)
            bind(mstmt, 5, excludedReasons[frameID])
            guard sqlite3_step(mstmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw ArchiveError.databaseError(dbErrorMessage())
            }
        }
        try exec("COMMIT")
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

    private func rowToFrameSet(_ stmt: OpaquePointer?) -> ArchivedFrameSet? {
        // Column map — see frameSetSelectSQL for ordering.
        // 0–13: v6 core, 14–21: v7 extras,
        // 22–26: v19 quality aggregates, 27: frame_count, 28: excluded_count,
        // 29–30: v24 telescope/site.
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

        var fs = ArchivedFrameSet(
            id: id,
            name: name,
            frameType: frameType,
            processingLevel: processingLevel,
            createdAt: createdAt,
            frameCount: Int(sqlite3_column_int(stmt, 27)),
            excludedFrameCount: Int(sqlite3_column_int(stmt, 28)),
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
            temperatureMax:  columnDouble(stmt, 18),
            medianStarCount:               columnDouble(stmt, 22),
            medianFWHM:                    columnDouble(stmt, 23),
            medianEccentricity:            columnDouble(stmt, 24),
            medianBackgroundNoise:         columnDouble(stmt, 25),
            medianBackgroundNoiseElectrons: columnDouble(stmt, 26)
        )
        // telescope (col 29) and site (col 30) added in migration v24.
        fs.telescope = columnText(stmt, 29)
        fs.site      = columnText(stmt, 30)
        return fs
    }

    // MARK: - Processing runs

    func insertProcessingRun(_ run: ArchivedProcessingRun, inputs: [ProcessingRunInputRef]) throws {
        let iso = ISO8601DateFormatter()
        try exec("BEGIN")

        let paramsJSON: String
        if run.parameters.isEmpty {
            paramsJSON = "{}"
        } else {
            let pairs = run.parameters.sorted(by: { $0.key < $1.key })
                .map { "\"\($0.key)\":\"\($0.value)\"" }
                .joined(separator: ",")
            paramsJSON = "{\(pairs)}"
        }

        let runSQL = "INSERT INTO processing_runs (id, pipeline_id, parameters, created_at) VALUES (?,?,?,?)"
        let rstmt = try prepare(runSQL)
        defer { sqlite3_finalize(rstmt) }
        bind(rstmt, 1, run.id.uuidString)
        bind(rstmt, 2, run.pipelineID)
        bind(rstmt, 3, paramsJSON)
        bind(rstmt, 4, iso.string(from: run.createdAt))
        guard sqlite3_step(rstmt) == SQLITE_DONE else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw ArchiveError.databaseError(dbErrorMessage())
        }

        let inputSQL = """
            INSERT INTO processing_run_inputs (run_id, input_name, frame_id, file_path, position)
            VALUES (?,?,?,?,?)
            """
        for ref in inputs {
            let istmt = try prepare(inputSQL)
            defer { sqlite3_finalize(istmt) }
            bind(istmt, 1, run.id.uuidString)
            bind(istmt, 2, ref.inputName)
            bind(istmt, 3, ref.frameID?.uuidString)
            bind(istmt, 4, ref.filePath)
            sqlite3_bind_int(istmt, 5, Int32(ref.position))
            guard sqlite3_step(istmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw ArchiveError.databaseError(dbErrorMessage())
            }
        }

        try exec("COMMIT")
    }

    func frameByFilePath(_ path: String) throws -> ArchivedFrame? {
        let stmt = try prepare("SELECT * FROM frames WHERE file_path = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrame(stmt) : nil
    }

    func frameBySignature(_ signature: String) throws -> ArchivedFrame? {
        let stmt = try prepare("SELECT * FROM frames WHERE frame_signature = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrame(stmt) : nil
    }

    func updateFrameRunID(id: UUID, processingRunID: UUID) throws {
        let stmt = try prepare("UPDATE frames SET processing_run_id = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, processingRunID.uuidString)
        bind(stmt, 2, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    func processingRunByID(_ id: UUID) throws -> ArchivedProcessingRun? {
        let stmt = try prepare(
            "SELECT id, pipeline_id, parameters, created_at FROM processing_runs WHERE id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToProcessingRun(stmt)
    }

    func inputsForRun(_ id: UUID) throws -> [ProcessingRunInputRef] {
        let stmt = try prepare("""
            SELECT input_name, frame_id, file_path, position
            FROM processing_run_inputs WHERE run_id = ? ORDER BY input_name, position
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var results: [ProcessingRunInputRef] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let inputName = columnText(stmt, 0) ?? ""
            let frameID   = columnText(stmt, 1).flatMap { UUID(uuidString: $0) }
            let filePath  = columnText(stmt, 2)
            let position  = Int(sqlite3_column_int(stmt, 3))
            results.append(ProcessingRunInputRef(
                inputName: inputName, frameID: frameID, filePath: filePath, position: position
            ))
        }
        return results
    }

    private func rowToProcessingRun(_ stmt: OpaquePointer?) -> ArchivedProcessingRun? {
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let pipelineID = columnText(stmt, 1),
              let createdAtStr = columnText(stmt, 3)
        else { return nil }

        let iso = ISO8601DateFormatter()
        let createdAt = iso.date(from: createdAtStr) ?? Date()

        // Parse simple JSON object {"key":"value",...} — no external dep needed.
        var parameters: [String: String] = [:]
        if let json = columnText(stmt, 2) {
            let stripped = json.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            if !stripped.isEmpty {
                for pair in stripped.components(separatedBy: ",") {
                    let kv = pair.components(separatedBy: "\":\"")
                    if kv.count == 2 {
                        let k = kv[0].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                        let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                        parameters[k] = v
                    }
                }
            }
        }

        return ArchivedProcessingRun(
            id: id, pipelineID: pipelineID, parameters: parameters, createdAt: createdAt
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

    func recentFrames(limit: Int) throws -> [ArchivedFrame] {
        let stmt = try prepare(
            "SELECT * FROM frames WHERE rejected = 0 ORDER BY added_at DESC LIMIT \(limit)"
        )
        defer { sqlite3_finalize(stmt) }
        var results: [ArchivedFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let f = rowToFrame(stmt) { results.append(f) }
        }
        return results
    }

    func listObjects() throws -> [(name: String, count: Int)] {
        try rows("SELECT object_name, COUNT(*) FROM frames WHERE object_name IS NOT NULL GROUP BY object_name ORDER BY object_name")
            .compactMap { row -> (String, Int)? in
                guard let n = row[0] as? String, let c = row[1] as? Int else { return nil }
                return (n, c)
            }
    }

    // MARK: - Row mapping

    // MARK: - Camera Profiles

    /// Inserts or updates a camera gain-setting → EGAIN mapping.
    /// Called automatically during archiving when a frame carries INSTRUME + GAIN + EGAIN.
    func upsertCameraProfile(cameraName: String, gainSetting: Double, egain: Double) throws {
        let sql = """
        INSERT INTO camera_profiles (camera_name, gain_setting, egain, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(camera_name, gain_setting) DO UPDATE SET
            egain      = excluded.egain,
            updated_at = excluded.updated_at
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()
        bind(stmt, 1, cameraName)
        bind(stmt, 2, gainSetting)
        bind(stmt, 3, egain)
        bind(stmt, 4, iso.string(from: Date()))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// Returns the stored EGAIN (e⁻/ADU) for a camera + gain-setting pair, or `nil` if unknown.
    func lookupEGain(cameraName: String, gainSetting: Double) throws -> Double? {
        let stmt = try prepare(
            "SELECT egain FROM camera_profiles WHERE camera_name = ? AND gain_setting = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, cameraName)
        bind(stmt, 2, gainSetting)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnDouble(stmt, 0)
    }

    private func rowToFrame(_ stmt: OpaquePointer?) -> ArchivedFrame? {
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let filePath = columnText(stmt, 1)
        else { return nil }

        let iso = ISO8601DateFormatter()
        var frame = ArchivedFrame(
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
            positionAngle: columnDouble(stmt, 28),
            processingRunID: columnText(stmt, 29).flatMap { UUID(uuidString: $0) },
            sessionBeg: columnText(stmt, 30).flatMap { iso.date(from: $0) },
            sessionEnd: columnText(stmt, 31).flatMap { iso.date(from: $0) },
            temperatureMin: columnDouble(stmt, 32),
            temperatureMax: columnDouble(stmt, 33),
            starCount: sqlite3_column_type(stmt, 34) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 34)) : nil,
            medianFWHM: columnDouble(stmt, 35),
            backgroundNoise: columnDouble(stmt, 36),
            medianEccentricity: columnDouble(stmt, 37),
            saturatedStarCount: sqlite3_column_type(stmt, 38) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 38)) : nil,
            hotPixelCount: sqlite3_column_type(stmt, 39) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 39)) : nil,
            egain: columnDouble(stmt, 40),
            backgroundNoiseElectrons: columnDouble(stmt, 41),
            stretchSettings: columnText(stmt, 42)
                .flatMap { Data($0.utf8) }
                .flatMap { try? JSONDecoder().decode(StretchSettings.self, from: $0) },
            sliderBlackNorm: columnDouble(stmt, 43).map { Float($0) },
            sliderWhiteNorm: columnDouble(stmt, 44).map { Float($0) }
        )
        // telescope (col 45) and site (col 46) added in migration v23.
        frame.telescope = columnText(stmt, 45)
        frame.site      = columnText(stmt, 46)
        return frame
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
