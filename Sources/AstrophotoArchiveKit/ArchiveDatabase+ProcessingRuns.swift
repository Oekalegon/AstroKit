import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Processing runs

    func insertProcessingRun(_ run: ArchivedProcessingRun, inputs: [ProcessingRunInputRef]) throws {
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
            INSERT INTO processing_run_inputs (run_id, input_name, frame_id, file_path, position, frameset_id)
            VALUES (?,?,?,?,?,?)
            """
        for ref in inputs {
            let istmt = try prepare(inputSQL)
            defer { sqlite3_finalize(istmt) }
            bind(istmt, 1, run.id.uuidString)
            bind(istmt, 2, ref.inputName)
            bind(istmt, 3, ref.frameID?.uuidString)
            bind(istmt, 4, ref.filePath)
            sqlite3_bind_int(istmt, 5, Int32(ref.position))
            bind(istmt, 6, ref.framesetID?.uuidString)
            guard sqlite3_step(istmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw ArchiveError.databaseError(dbErrorMessage())
            }
        }

        try exec("COMMIT")
    }

    /// Finds the most recent processed frame produced by a previous run of the same pipeline
    /// that represents the "same work." Strategy chosen by input type:
    ///
    /// 1. **FrameSet input** (`inputFramesetID != nil`): match runs that used the same
    ///    FrameSet. Dropping or adding members between runs is captured in `FrameDiff`;
    ///    it does not break the lineage chain.
    /// 2. **Single-frame input** (`singleInputFrameID != nil`): match runs that processed
    ///    the exact same source frame (e.g., calibration pipelines where each raw frame
    ///    has its own independent history).
    /// 3. **Fallback — target match**: match on `object_name`, `frame_type`, and `filter`
    ///    when the run had no FrameSet reference and more than one input frame (i.e., ad-hoc
    ///    stacking runs not associated with a named FrameSet).
    func findPredecessorFrame(
        pipelineID: String,
        excludingRunID: UUID,
        inputFramesetID: UUID?,
        singleInputFrameID: UUID?,
        objectName: String?,
        frameType: String,
        filter: String?
    ) throws -> ArchivedFrame? {
        if let framesetID = inputFramesetID {
            // Strategy 1: same FrameSet — any change in member count still links
            let sql = """
            SELECT f.* FROM frames f
              JOIN processing_runs r ON f.processing_run_id = r.id
              JOIN processing_run_inputs pri ON pri.run_id = r.id AND pri.frameset_id = ?
             WHERE r.pipeline_id = ?
               AND r.id != ?
               AND f.processing_level != 'raw'
             ORDER BY f.added_at DESC
             LIMIT 1
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, framesetID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, pipelineID,            -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, excludingRunID.uuidString, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrame(stmt) : nil
        } else if let frameID = singleInputFrameID {
            // Strategy 2: same source frame (calibration, registration of individual frames)
            let sql = """
            SELECT f.* FROM frames f
              JOIN processing_runs r ON f.processing_run_id = r.id
              JOIN processing_run_inputs pri ON pri.run_id = r.id AND pri.frame_id = ?
             WHERE r.pipeline_id = ?
               AND r.id != ?
               AND f.processing_level != 'raw'
             ORDER BY f.added_at DESC
             LIMIT 1
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, frameID.uuidString,    -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, pipelineID,            -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, excludingRunID.uuidString, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrame(stmt) : nil
        } else {
            // Strategy 3: ad-hoc multi-frame run — match on result frame target characteristics
            let sql = """
            SELECT f.* FROM frames f
              JOIN processing_runs r ON f.processing_run_id = r.id
             WHERE r.pipeline_id = ?
               AND r.id != ?
               AND f.processing_level != 'raw'
               AND LOWER(COALESCE(f.object_name, '')) = LOWER(COALESCE(?, ''))
               AND LOWER(f.frame_type) = LOWER(?)
               AND LOWER(COALESCE(f.filter, '')) = LOWER(COALESCE(?, ''))
             ORDER BY f.added_at DESC
             LIMIT 1
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pipelineID,                -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, excludingRunID.uuidString, -1, SQLITE_TRANSIENT)
            bind(stmt, 3, objectName)
            sqlite3_bind_text(stmt, 4, frameType,                 -1, SQLITE_TRANSIENT)
            bind(stmt, 5, filter)
            return sqlite3_step(stmt) == SQLITE_ROW ? rowToFrame(stmt) : nil
        }
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

    func updateFrameSupersedesID(id: UUID, supersedesID: UUID?) throws {
        let stmt = try prepare("UPDATE frames SET supersedes_id = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        if let sid = supersedesID {
            bind(stmt, 1, sid.uuidString)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        bind(stmt, 2, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// Returns the full lineage chain starting from `id`, ordered newest-to-oldest.
    ///
    /// Uses a single recursive CTE so the entire chain is fetched in one SQLite query
    /// regardless of depth — O(1) actor hops instead of O(N). The `_depth` counter
    /// appended by the CTE lands at column 48, safely beyond the range `rowToFrame`
    /// reads (0–47), so no mapper changes are needed. Depth is capped at 999 rows
    /// (WHERE clause in the recursive term) as a cycle guard against corrupt data.
    func lineageChain(startingAt id: UUID) throws -> [ArchivedFrame] {
        let sql = """
        WITH RECURSIVE chain AS (
            SELECT *, 0 AS _depth FROM frames WHERE id = ?
            UNION ALL
            SELECT f.*, c._depth + 1 FROM frames f
            JOIN chain c ON f.id = c.supersedes_id
            WHERE c._depth < 999
        )
        SELECT * FROM chain ORDER BY _depth
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var results: [ArchivedFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let f = rowToFrame(stmt) { results.append(f) }
        }
        return results
    }

    /// Returns all frames that directly supersede the given frame ID (i.e. frames whose
    /// `supersedes_id` equals `id`). Typically zero or one, but the schema allows multiple.
    func successors(of id: UUID) throws -> [ArchivedFrame] {
        let stmt = try prepare("SELECT * FROM frames WHERE supersedes_id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var results: [ArchivedFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let f = rowToFrame(stmt) { results.append(f) }
        }
        return results
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
            SELECT input_name, frame_id, file_path, position, frameset_id
            FROM processing_run_inputs WHERE run_id = ? ORDER BY input_name, position
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var results: [ProcessingRunInputRef] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let inputName  = columnText(stmt, 0) ?? ""
            let frameID    = columnText(stmt, 1).flatMap { UUID(uuidString: $0) }
            let filePath   = columnText(stmt, 2)
            let position   = Int(sqlite3_column_int(stmt, 3))
            let framesetID = columnText(stmt, 4).flatMap { UUID(uuidString: $0) }
            results.append(ProcessingRunInputRef(
                inputName: inputName, frameID: frameID, filePath: filePath, position: position, framesetID: framesetID
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
}
