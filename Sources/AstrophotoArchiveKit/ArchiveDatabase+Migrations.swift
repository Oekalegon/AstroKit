import Foundation
import SQLite3

extension ArchiveDatabase {

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

    // MARK: - Migrations

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
        // v25: calibration frames (bias/dark/flat) do not image a sky target — the
        // OBJECT / RA / DEC their capture software wrote is leftover mount state from
        // the preceding light frames. Clear them on existing rows; FITSHeaderReader no
        // longer extracts them for these frame types on import. healpix_pixel is derived
        // from ra/dec and must be cleared with them.
        """
        UPDATE frames SET object_name = NULL, ra = NULL, dec = NULL, healpix_pixel = NULL
        WHERE LOWER(frame_type) IN ('bias', 'dark', 'flat');
        UPDATE frame_sets SET object_name = NULL
        WHERE LOWER(frame_type) IN ('bias', 'dark', 'flat');
        """,
        // v26: re-run the v25 cleanup. A metadata backfill executed with a pre-v25 binary
        // (a stale long-running MCP server process) re-read the FITS files — which still
        // carry the OBJECT keyword on disk — and wrote object_name back onto calibration
        // rows after v25 had cleared it. backfillObservationMetadata now refuses to write
        // an object for calibration frame types, so this cannot recur.
        """
        UPDATE frames SET object_name = NULL, ra = NULL, dec = NULL, healpix_pixel = NULL
        WHERE LOWER(frame_type) IN ('bias', 'dark', 'flat');
        UPDATE frame_sets SET object_name = NULL
        WHERE LOWER(frame_type) IN ('bias', 'dark', 'flat');
        """,
        // v27: persist the selection criteria a frameset was created with (JSON-encoded
        // FrameSetCriteria). Frames added to an existing set are validated against these
        // criteria so the set stays consistent with its original query. NULL for sets
        // created before this version — those only get the type/level/filter checks.
        "ALTER TABLE frame_sets ADD COLUMN criteria TEXT;",
        // v28: pipeline result lineage — each processed frame can point to the earlier
        // result it supersedes, forming a linked list from newest to oldest for a given
        // frameset/pipeline combination. Applies to any pipeline output (stacking,
        // calibration, registration, …), not just stacking. ON DELETE SET NULL so that
        // deleting an old result does not cascade to its successor.
        """
        ALTER TABLE frames ADD COLUMN supersedes_id TEXT REFERENCES frames(id) ON DELETE SET NULL;
        CREATE INDEX IF NOT EXISTS idx_frames_supersedes ON frames(supersedes_id);
        """,
        // v29: track which FrameSet each processing_run_inputs row came from. Populated when
        // the pipeline is run with a named FrameSet as input. Allows predecessor matching to
        // link on FrameSet identity (not frame membership), so dropping/adding frames between
        // runs of the same FrameSet still resolves to the same lineage chain.
        "ALTER TABLE processing_run_inputs ADD COLUMN frameset_id TEXT REFERENCES frame_sets(id) ON DELETE SET NULL;",
        // v30: fix a typo in v29 that referenced `framesets` instead of `frame_sets`. With
        // PRAGMA foreign_keys = ON, the wrong FK caused every INSERT into processing_run_inputs
        // to fail with "no such table: main.framesets". DROP + re-ADD corrects the schema.
        """
        ALTER TABLE processing_run_inputs DROP COLUMN frameset_id;
        ALTER TABLE processing_run_inputs ADD COLUMN frameset_id TEXT REFERENCES frame_sets(id) ON DELETE SET NULL;
        """,
        // v31: observing sessions. Each session represents one night (or day, for solar)
        // of imaging from a single geographic location. Sessions are auto-created when raw
        // frames with a timestamp and site coordinates are archived, and frames are linked
        // to their session via session_id. site_latitude and site_longitude store the
        // observer's geographic position parsed from FITS headers (SITELAT/SITELONG etc.).
        """
        ALTER TABLE frames ADD COLUMN site_latitude REAL;
        ALTER TABLE frames ADD COLUMN site_longitude REAL;
        ALTER TABLE frames ADD COLUMN session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL;
        CREATE TABLE IF NOT EXISTS sessions (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            date        TEXT NOT NULL,
            is_night    INTEGER NOT NULL DEFAULT 1,
            latitude    REAL NOT NULL,
            longitude   REAL NOT NULL,
            frame_count INTEGER NOT NULL DEFAULT 0,
            start_time  TEXT,
            end_time    TEXT,
            added_at    TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_date ON sessions(date);
        CREATE INDEX IF NOT EXISTS idx_frames_session ON frames(session_id);
        """,
        // v32: calibration sessions. Extends the sessions table with columns that describe
        // calibration sessions (dark/flat/bias sequences). At this point frame_type IS NULL
        // means a light session (upgraded to 'light' in v33). temperature_hint/filter_hint store the
        // representative CCD temperature and filter used when matching new frames to an open
        // calibration session and when naming the session. Calibration sessions use 0/0 for
        // latitude/longitude (no location required).
        """
        ALTER TABLE sessions ADD COLUMN frame_type TEXT;
        ALTER TABLE sessions ADD COLUMN temperature_hint REAL;
        ALTER TABLE sessions ADD COLUMN filter_hint TEXT;
        CREATE INDEX IF NOT EXISTS idx_sessions_frame_type ON sessions(frame_type);
        """,
        // v33: give light sessions an explicit frame_type = 'light' so that all sessions
        // carry a non-NULL frame_type and the model can expose it uniformly.
        """
        UPDATE sessions SET frame_type = 'light' WHERE frame_type IS NULL;
        """,
        // v34: celestial context metrics computed by the frame_quality pipeline's
        // celestial_context step. sun_altitude is the Sun's altitude in degrees at
        // observation time (negative = below horizon). moon_elongation is the angular
        // separation between the Moon and the target field in degrees. moon_illumination
        // is the Moon's illuminated fraction 0–1 (0 = new, 1 = full).
        """
        ALTER TABLE frames ADD COLUMN sun_altitude REAL;
        ALTER TABLE frames ADD COLUMN moon_elongation REAL;
        ALTER TABLE frames ADD COLUMN moon_illumination REAL;
        """,
    ]

    static func applyMigrations(db: OpaquePointer) throws {
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
    static func normalizeFilePaths(db: OpaquePointer, archiveRootPath: String) {
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
        sqlite3_bind_text(stmt, 2, prefix + "%", -1, ArchiveDatabase.sqliteTransient)
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
        sqlite3_bind_text(tstmt, 2, prefix + "%", -1, ArchiveDatabase.sqliteTransient)
        sqlite3_step(tstmt)
    }
}
