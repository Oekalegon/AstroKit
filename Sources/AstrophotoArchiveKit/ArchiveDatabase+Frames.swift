import AstrophotoKit
import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Insert

    /// Inserts a frame record.
    ///
    /// - Parameter deduplicate: When `true` (default), uses `INSERT OR IGNORE` and stores a
    ///   `frame_signature` so that re-importing the same raw observation is a no-op. Pass `false`
    ///   for processed/stacked results, which should always produce a new archive record regardless
    ///   of whether a frame with the same signature already exists. In that case `frame_signature`
    ///   is stored as NULL so the UNIQUE index is not triggered.
    /// - Returns: `true` if the row was inserted, `false` if a duplicate was ignored
    ///   (only possible when `deduplicate` is `true`).
    @discardableResult
    func insertFrame(_ frame: ArchivedFrame, deduplicate: Bool = true) throws -> Bool {
        let verb = deduplicate ? "INSERT OR IGNORE" : "INSERT"
        let sql = """
        \(verb) INTO frames
        (id, file_path, object_name, ra, dec, healpix_pixel, frame_type,
         filter, camera, focal_length, pixel_scale, temperature, timestamp,
         exposure_time, gain, offset, width, height, bitpix,
         calibrated, stacked, stretched, processing_level, added_at, thumbnail,
         frame_signature, rejected, rejected_reason, position_angle, processing_run_id,
         session_beg, session_end, temperature_min, temperature_max,
         star_count, median_fwhm, background_noise, median_eccentricity,
         saturated_star_count, hot_pixel_count, egain, background_noise_electrons,
         telescope, site, supersedes_id, site_latitude, site_longitude, session_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
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
        bind(stmt, 26, deduplicate ? ArchiveDatabase.frameSignature(
            fileDate: frame.fileDate,
            frameType: frame.frameType,
            filter: frame.filter,
            exposureTime: frame.exposureTime
        ) : nil)
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
        bind(stmt, 45, frame.supersedesID?.uuidString)
        bind(stmt, 46, frame.siteLatitude)
        bind(stmt, 47, frame.siteLongitude)
        bind(stmt, 48, frame.sessionID?.uuidString)

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

    func recentFrames(limit: Int?, rejectionFilter: RejectionFilter = .excludeRejected) throws -> [ArchivedFrame] {
        let condition: String
        switch rejectionFilter {
        case .excludeRejected: condition = "WHERE rejected = 0 "
        case .onlyRejected:    condition = "WHERE rejected = 1 "
        case .includeAll:      condition = ""
        }
        // max(_:0) keeps an explicit non-positive limit from becoming SQLite's "LIMIT -1" (unlimited).
        let limitClause = limit.map { " LIMIT \(max($0, 0))" } ?? ""
        let stmt = try prepare(
            "SELECT * FROM frames \(condition)ORDER BY added_at DESC\(limitClause)"
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

    // MARK: - Update

    /// Updates the timestamp (DATE-OBS) for a single frame.
    func updateTimestamp(id: UUID, timestamp: Date) throws {
        let sql = "UPDATE frames SET timestamp = ? WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, iso.string(from: timestamp))
        bind(stmt, 2, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

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

    /// Updates numeric acquisition fields for a single frame.
    /// Only non-nil arguments are written; existing values are never overwritten with NULL.
    /// When `exposureTime` is updated, `newFrameSignature` must be provided so the
    /// deduplication index stays consistent. Uses OR IGNORE to silently skip if the new
    /// signature already exists (which would mean a true duplicate is already in the archive).
    func updateAcquisitionMetadata(
        id: UUID,
        exposureTime: Double?,
        gain: Double?,
        offset: Double?,
        temperature: Double?,
        egain: Double?,
        focalLength: Double?,
        pixelScale: Double?,
        positionAngle: Double?,
        siteLatitude: Double? = nil,
        siteLongitude: Double? = nil,
        newFrameSignature: String? = nil
    ) throws {
        var setClauses: [String] = []
        var doubles: [(String, Double)] = []
        var strings: [(String, String)] = []
        if let v = exposureTime  { setClauses.append("exposure_time = ?");  doubles.append(("exposure_time",  v)) }
        if let v = gain          { setClauses.append("gain = ?");            doubles.append(("gain",           v)) }
        if let v = offset        { setClauses.append("offset = ?");          doubles.append(("offset",         v)) }
        if let v = temperature   { setClauses.append("temperature = ?");     doubles.append(("temperature",    v)) }
        if let v = egain         { setClauses.append("egain = ?");           doubles.append(("egain",          v)) }
        if let v = focalLength   { setClauses.append("focal_length = ?");    doubles.append(("focal_length",   v)) }
        if let v = pixelScale    { setClauses.append("pixel_scale = ?");     doubles.append(("pixel_scale",    v)) }
        if let v = positionAngle { setClauses.append("position_angle = ?");  doubles.append(("position_angle", v)) }
        if let v = siteLatitude  { setClauses.append("site_latitude = ?");   doubles.append(("site_latitude",  v)) }
        if let v = siteLongitude { setClauses.append("site_longitude = ?");  doubles.append(("site_longitude", v)) }
        if let v = newFrameSignature { setClauses.append("frame_signature = ?"); strings.append(("frame_signature", v)) }
        guard !setClauses.isEmpty else { return }

        let sql = "UPDATE OR IGNORE frames SET \(setClauses.joined(separator: ", ")) WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var pos: Int32 = 1
        for (_, v) in doubles { sqlite3_bind_double(stmt, pos, v); pos += 1 }
        for (_, v) in strings { bind(stmt, pos, v); pos += 1 }
        bind(stmt, pos, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// Bulk-sets `pixel_scale` on all frames and framesets matching the given
    /// telescope and/or camera (exact match; nil filters are ignored).
    /// Unless `overwrite` is true, only rows whose pixel_scale is NULL are touched.
    /// Returns the number of rows updated per table.
    func bulkSetPixelScale(
        _ value: Double,
        telescope: String?,
        camera: String?,
        overwrite: Bool
    ) throws -> (frames: Int, frameSets: Int) {
        let frames    = try bulkSetPixelScale(value, table: "frames",     telescope: telescope, camera: camera, overwrite: overwrite)
        let frameSets = try bulkSetPixelScale(value, table: "frame_sets", telescope: telescope, camera: camera, overwrite: overwrite)
        return (frames, frameSets)
    }

    private func bulkSetPixelScale(
        _ value: Double,
        table: String,
        telescope: String?,
        camera: String?,
        overwrite: Bool
    ) throws -> Int {
        var conditions: [String] = []
        var strings: [String] = []
        if let t = telescope { conditions.append("telescope = ?"); strings.append(t) }
        if let c = camera    { conditions.append("camera = ?");    strings.append(c) }
        if !overwrite { conditions.append("pixel_scale IS NULL") }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let sql = "UPDATE \(table) SET pixel_scale = ?\(whereClause)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, value)
        for (i, s) in strings.enumerated() { bind(stmt, Int32(i + 2), s) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        return Int(sqlite3_changes(db))
    }

    /// Sets pixel_scale on a single frameset.
    func updateFrameSetPixelScale(id: UUID, pixelScale: Double) throws {
        let sql = "UPDATE frame_sets SET pixel_scale = ? WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, pixelScale)
        bind(stmt, 2, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
    }

    /// Updates quality metrics on a frame. Only non-nil values are written;
    /// passing `nil` for a metric leaves the existing DB value unchanged.
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

    // MARK: - Row mapping

    func rowToFrame(_ stmt: OpaquePointer?) -> ArchivedFrame? {
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let filePath = columnText(stmt, 1)
        else { return nil }

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
        frame.telescope    = columnText(stmt, 45)
        frame.site         = columnText(stmt, 46)
        // supersedes_id (col 47) added in migration v28.
        frame.supersedesID = columnText(stmt, 47).flatMap { UUID(uuidString: $0) }
        // site_latitude (col 48), site_longitude (col 49), session_id (col 50) added in migration v31.
        frame.siteLatitude  = columnDouble(stmt, 48)
        frame.siteLongitude = columnDouble(stmt, 49)
        frame.sessionID     = columnText(stmt, 50).flatMap { UUID(uuidString: $0) }
        return frame
    }
}
