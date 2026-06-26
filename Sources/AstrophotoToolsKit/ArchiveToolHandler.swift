import AstrophotoArchiveKit
import AstrophotoToolDefinitions
import Foundation

public struct ArchiveToolHandler {

    public let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    // MARK: - Tool definitions

    public static let definitions: [[String: Any]] = ArchiveToolDefinitions.all

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "archive_add":               return try await archiveAdd(arguments)
        case "archive_get":               return try await archiveGet(arguments)
        case "archive_search":            return try await archiveSearch(arguments)
        case "archive_recent":            return try await archiveRecent(arguments)
        case "archive_list_objects":      return try await archiveListObjects()
        case "archive_stats":             return try await archiveStats()
        case "archive_remove":            return try await archiveRemove(arguments)
        case "archive_reject":            return try await archiveReject(arguments)
        case "archive_update_quality":    return try await archiveUpdateQuality(arguments)
        case "archive_update_stretch":    return try await archiveUpdateStretch(arguments)
        case "archive_frameset_inspect":  return try await archiveFrameSetInspect(arguments)
        case "archive_frameset_create":   return try await archiveFrameSetCreate(arguments)
        case "archive_frameset_get":      return try await archiveFrameSetGet(arguments)
        case "archive_frameset_quality":  return try await archiveFrameSetQuality(arguments)
        case "archive_frameset_add":      return try await archiveFrameSetAdd(arguments)
        case "archive_frameset_remove":   return try await archiveFrameSetRemove(arguments)
        case "archive_frameset_exclude":  return try await archiveFrameSetExclude(arguments)
        case "archive_frameset_delete":   return try await archiveFrameSetDelete(arguments)
        case "archive_backfill_metadata": return try await archiveBackfillMetadata(arguments)
        case "archive_sessions":          return try await archiveSessions(arguments)
        case "archive_backfill_sessions": return try await archiveBackfillSessions()
        case "archive_session_frames":    return try await archiveSessionFrames(arguments)
        case "archive_frame_session":     return try await archiveFrameSession(arguments)
        case "archive_set_pixel_scale":   return try await archiveSetPixelScale(arguments)
        case "archive_frame_lineage":     return try await archiveFrameLineage(arguments)
        default: throw ToolError("Unknown archive tool: \(name)")
        }
    }

    // MARK: - Shared helpers

    func makeFrameSetQuery(_ args: [String: Any]) -> FrameQuery {
        var query = FrameQuery()
        query.objectName = args["object_name"] as? String
        query.camera     = args["camera"]      as? String
        query.telescope  = args["telescope"]   as? String
        query.site       = args["site"]        as? String
        query.gain       = args["gain"]        as? Double
        query.offset     = args["offset"]      as? Double
        if let minExp = args["min_exposure"] as? Double,
           let maxExp = args["max_exposure"] as? Double {
            query.exposureTimeRange = minExp...maxExp
        } else if let minExp = args["min_exposure"] as? Double {
            query.exposureTimeRange = minExp...Double.infinity
        } else if let maxExp = args["max_exposure"] as? Double {
            query.exposureTimeRange = 0...maxExp
        }
        if let minFL = args["min_focal_length"] as? Double,
           let maxFL = args["max_focal_length"] as? Double {
            query.focalLengthRange = minFL...maxFL
        } else if let minFL = args["min_focal_length"] as? Double {
            query.focalLengthRange = minFL...Double.infinity
        } else if let maxFL = args["max_focal_length"] as? Double {
            query.focalLengthRange = 0...maxFL
        }
        if let minApt = args["min_aperture"] as? Double,
           let maxApt = args["max_aperture"] as? Double {
            query.apertureRange = minApt...maxApt
        } else if let minApt = args["min_aperture"] as? Double {
            query.apertureRange = minApt...Double.infinity
        } else if let maxApt = args["max_aperture"] as? Double {
            query.apertureRange = 0...maxApt
        }
        if let minPx = args["min_pixel_size"] as? Double,
           let maxPx = args["max_pixel_size"] as? Double {
            query.pixelSizeRange = minPx...maxPx
        } else if let minPx = args["min_pixel_size"] as? Double {
            query.pixelSizeRange = minPx...Double.infinity
        } else if let maxPx = args["max_pixel_size"] as? Double {
            query.pixelSizeRange = 0...maxPx
        }
        query.binning    = args["binning"]      as? Int
        query.filters    = args["filters"]     as? [String]
        if let t = args["frame_type"] as? String { query.frameTypes = [t] }
        if let lvl = args["processing_level"] as? String {
            query.processingLevel = ProcessingLevel(rawValue: lvl)
        }
        if let cal = args["calibrated"] as? Bool { query.calibrated = cal }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        if let fromStr = args["from_date"] as? String,
           let toStr   = args["to_date"]   as? String,
           let fromDate = df.date(from: fromStr),
           let toDate   = df.date(from: toStr) {
            query.dateRange = DateInterval(start: fromDate, end: toDate)
        }
        if let center = args["temp_center"] as? Double {
            let tol = args["temp_tolerance"] as? Double ?? 2.0
            query.temperatureRange = (center - tol)...(center + tol)
        }
        if let lo = args["min_pixel_scale"] as? Double, let hi = args["max_pixel_scale"] as? Double { query.pixelScaleRange = lo...hi }
        else if let lo = args["min_pixel_scale"] as? Double { query.pixelScaleRange = lo...Double.infinity }
        else if let hi = args["max_pixel_scale"] as? Double { query.pixelScaleRange = 0...hi }
        if let lo = args["min_width"] as? Int, let hi = args["max_width"] as? Int { query.widthRange = lo...hi }
        else if let lo = args["min_width"] as? Int { query.widthRange = lo...Int.max }
        else if let hi = args["max_width"] as? Int { query.widthRange = 0...hi }
        if let lo = args["min_height"] as? Int, let hi = args["max_height"] as? Int { query.heightRange = lo...hi }
        else if let lo = args["min_height"] as? Int { query.heightRange = lo...Int.max }
        else if let hi = args["max_height"] as? Int { query.heightRange = 0...hi }
        query.bitpix = args["bitpix"] as? Int
        if let lo = args["min_egain"] as? Double, let hi = args["max_egain"] as? Double { query.egainRange = lo...hi }
        else if let lo = args["min_egain"] as? Double { query.egainRange = lo...Double.infinity }
        else if let hi = args["max_egain"] as? Double { query.egainRange = 0...hi }
        if let lo = args["min_position_angle"] as? Double,
           let hi = args["max_position_angle"] as? Double { query.positionAngleRange = lo...hi }
        else if let lo = args["min_position_angle"] as? Double { query.positionAngleRange = lo...360.0 }
        else if let hi = args["max_position_angle"] as? Double { query.positionAngleRange = 0...hi }
        query.addedAfter  = (args["added_after"]  as? String).flatMap { df.date(from: $0) }
        query.addedBefore = (args["added_before"] as? String).flatMap { df.date(from: $0) }
        query.minStarCount           = args["min_stars"]                as? Int
        query.maxBackgroundNoise     = args["max_background_noise"]     as? Double
        query.maxSaturatedStarCount  = args["max_saturated_star_count"] as? Int
        query.maxHotPixelCount       = args["max_hot_pixel_count"]      as? Int
        query.maxSunAltitude         = args["max_sun_altitude"]         as? Double
        query.minMoonSeparation      = args["min_moon_separation"]      as? Double
        query.maxMoonIllumination    = args["max_moon_illumination"]    as? Double
        return query
    }

    func medianValue(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 0
            ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
            : sorted[n / 2]
    }
}
