import Foundation
import SQLite3

extension ArchiveDatabase {

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
            availableBytes: availableSpace(at: archiveRoot),
            totalBytes: totalSpace(at: archiveRoot)
        )
    }

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
        bind(stmt, 1, cameraName)
        sqlite3_bind_double(stmt, 2, gainSetting)
        sqlite3_bind_double(stmt, 3, egain)
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
        sqlite3_bind_double(stmt, 2, gainSetting)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnDouble(stmt, 0)
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
        volumeCapacity(at: url, key: .volumeAvailableCapacityKey) { $0.volumeAvailableCapacity }
    }

    private func totalSpace(at url: URL) -> Int64 {
        volumeCapacity(at: url, key: .volumeTotalCapacityKey) { $0.volumeTotalCapacity }
    }

    /// Reads a volume-capacity resource value, returning 0 when unknown.
    private func volumeCapacity(
        at url: URL, key: URLResourceKey, value: (URLResourceValues) -> Int?
    ) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [key]),
              let capacity = value(values) else { return 0 }
        return Int64(capacity)
    }
}
