import Foundation
import SQLite3

extension ArchiveDatabase {

    // MARK: - Criteria JSON coding

    static func encodeCriteria(_ criteria: FrameSetCriteria?) -> String? {
        guard let criteria else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(criteria)
            return String(data: data, encoding: .utf8)
        } catch {
            assertionFailure("FrameSetCriteria encoding failed — check Codable conformance: \(error)")
            return nil
        }
    }

    static func decodeCriteria(_ json: String?) -> FrameSetCriteria? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FrameSetCriteria.self, from: data)
    }

    // MARK: - Row mapping

    func rowToFrameSet(_ stmt: OpaquePointer?) -> ArchivedFrameSet? {
        // Column map — see frameSetSelectSQL for ordering.
        // 0–13: v6 core, 14–21: v7 extras,
        // 22–26: v19 quality aggregates, 27: frame_count, 28: excluded_count,
        // 29–30: v24 telescope/site, 31: v27 criteria.
        guard let stmt,
              let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
              let name = columnText(stmt, 1),
              let frameType = columnText(stmt, 2),
              let levelStr = columnText(stmt, 3),
              let createdAtStr = columnText(stmt, 13)
        else { return nil }

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
        // criteria (col 31) added in migration v27.
        fs.criteria  = ArchiveDatabase.decodeCriteria(columnText(stmt, 31))
        return fs
    }
}
