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
         telescope, site, supersedes_id, site_latitude, site_longitude, session_id,
         sun_altitude, moon_elongation, moon_illumination)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        bind(stmt, 49, frame.sunAltitude)
        bind(stmt, 50, frame.moonElongation)
        bind(stmt, 51, frame.moonIllumination)

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
}
