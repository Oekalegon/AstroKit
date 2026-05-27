import Foundation
import AstrophotoArchiveKit

struct ArchiveTools {

    // MARK: - Tool definitions

    static let definitions: [[String: Any]] = [
        [
            "name": "archive_add",
            "description": "Add a FITS file or directory of FITS files to the astrophoto archive. Reads metadata from FITS headers automatically.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Absolute path to a FITS file or directory.",
                    ],
                    "recursive": [
                        "type": "boolean",
                        "description": "Recurse into subdirectories (when path is a directory). Default false.",
                    ],
                ] as [String: Any],
                "required": ["path"],
            ] as [String: Any],
        ],
        [
            "name": "archive_get",
            "description": "Show all stored information for a single archive frame by UUID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID (from archive_find)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_find",
            "description": "Search the archive for frames matching a query. Returns matching frames as JSON.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "object_name": [
                        "type": "string",
                        "description": "Partial object name to match (e.g. 'M51').",
                    ],
                    "frame_types": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Frame types to include (light, dark, flat, bias).",
                    ],
                    "filters": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Filters to include (Hɑ, SII, OIII, R, G, B, L).",
                    ],
                    "processing_level": [
                        "type": "string",
                        "enum": ["raw", "calibrated", "stacked", "stretched"],
                        "description": "Filter by processing level.",
                    ],
                    "calibrated": [
                        "type": "boolean",
                        "description": "Only return calibrated frames.",
                    ],
                    "stacked": [
                        "type": "boolean",
                        "description": "Only return stacked frames.",
                    ],
                    "ra": ["type": "number", "description": "Cone search centre RA (degrees)."],
                    "dec": ["type": "number", "description": "Cone search centre Dec (degrees)."],
                    "radius_deg": ["type": "number", "description": "Cone search radius (degrees)."],
                    "limit": ["type": "integer", "description": "Maximum number of results."],
                    "include_rejected": ["type": "boolean", "description": "Include rejected frames in results (default false)."],
                    "rejected_only": ["type": "boolean", "description": "Return only rejected frames."],
                    "max_fwhm": ["type": "number", "description": "Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded."],
                    "min_stars": ["type": "integer", "description": "Only frames with at least this many detected stars. Frames without quality data are excluded."],
                    "max_background_noise": ["type": "number", "description": "Only frames with background noise ≤ this value (ADU for frames processed with quality pipelines). Frames without quality data are excluded."],
                    "max_eccentricity": ["type": "number", "description": "Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded."],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_list_objects",
            "description": "List all objects in the archive with their frame counts.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "archive_stats",
            "description": "Get archive statistics: frame counts by type/filter, disk usage, and objects.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_inspect",
            "description": "Dry-run: inspect which frames would be included in a frame set and report property distributions (cameras, filters, date span, temperature range, pixel scales, position angles, …) without writing to the database. Use this before archive_frameset_create to check frame compatibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "frame_type": ["type": "string", "enum": ["light", "dark", "flat", "bias"], "description": "Frame type to inspect."],
                    "object_name": ["type": "string", "description": "Partial object name to match (e.g. 'M51')."],
                    "filters": ["type": "array", "items": ["type": "string"], "description": "Optical filters to include (Hɑ, SII, OIII, R, G, B, L)."],
                    "camera": ["type": "string", "description": "Camera name (exact match)."],
                    "from_date": ["type": "string", "description": "Start date YYYY-MM-DD."],
                    "to_date": ["type": "string", "description": "End date YYYY-MM-DD."],
                    "processing_level": ["type": "string", "enum": ["raw", "calibrated", "stacked", "stretched"], "description": "Filter by processing level."],
                    "calibrated": ["type": "boolean", "description": "Only calibrated frames."],
                    "temp_center": ["type": "number", "description": "Centre temperature in °C for dark frame grouping."],
                    "temp_tolerance": ["type": "number", "description": "Temperature tolerance ±°C (default 2.0)."],
                    "max_fwhm": ["type": "number", "description": "Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded."],
                    "min_stars": ["type": "integer", "description": "Only frames with at least this many detected stars. Frames without quality data are excluded."],
                    "max_background_noise": ["type": "number", "description": "Only frames with background noise ≤ this value (ADU for frames processed with quality pipelines). Frames without quality data are excluded."],
                    "max_eccentricity": ["type": "number", "description": "Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded."],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_create",
            "description": "Create a named frame set by querying the archive. All matched frames must share the same frame type and processing level. Mixed optical filters are blocked by default — set force=true to allow them (stored as a comma-separated list). Rejected frames are automatically excluded. Always returns the inspection report alongside the new set.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Name for the frame set. Auto-generated from query parameters if omitted."],
                    "frame_type": ["type": "string", "enum": ["light", "dark", "flat", "bias"], "description": "Frame type to include (required — a set is homogeneous)."],
                    "object_name": ["type": "string", "description": "Partial object name to match (e.g. 'M51')."],
                    "filters": ["type": "array", "items": ["type": "string"], "description": "Optical filters to include (Hɑ, SII, OIII, R, G, B, L)."],
                    "camera": ["type": "string", "description": "Camera name (exact match)."],
                    "from_date": ["type": "string", "description": "Start date YYYY-MM-DD."],
                    "to_date": ["type": "string", "description": "End date YYYY-MM-DD."],
                    "processing_level": ["type": "string", "enum": ["raw", "calibrated", "stacked", "stretched"], "description": "Filter by processing level."],
                    "calibrated": ["type": "boolean", "description": "Only calibrated frames."],
                    "temp_center": ["type": "number", "description": "Centre temperature in °C for dark frame grouping."],
                    "temp_tolerance": ["type": "number", "description": "Temperature tolerance ±°C (default 2.0)."],
                    "max_fwhm": ["type": "number", "description": "Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded."],
                    "min_stars": ["type": "integer", "description": "Only frames with at least this many detected stars. Frames without quality data are excluded."],
                    "max_background_noise": ["type": "number", "description": "Only frames with background noise ≤ this value (ADU for frames processed with quality pipelines). Frames without quality data are excluded."],
                    "max_eccentricity": ["type": "number", "description": "Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded."],
                    "force": ["type": "boolean", "description": "Allow mixed optical filters; stored as comma-separated list on the frame set (default false)."],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_list",
            "description": "List all frame sets in the archive.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_get",
            "description": "Get details of a frame set, including its member frames.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Frame set UUID."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_delete",
            "description": "Delete a frame set. Member frames are not removed from the archive.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Frame set UUID."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_recent",
            "description": "List the most recently archived frames, newest first. Useful for seeing what was just added or produced by a pipeline run.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of frames to return (default: 15).",
                    ],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_remove",
            "description": "Remove a frame from the archive by its UUID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID."],
                    "delete_file": ["type": "boolean", "description": "Also delete the FITS file from disk."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_reject",
            "description": "Mark a frame as rejected (excluded from processing) or clear the rejection flag.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID."],
                    "reason": ["type": "string", "description": "Optional reason for rejection."],
                    "undo": ["type": "boolean", "description": "Set to true to clear the rejection flag (un-reject)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_update_quality",
            "description": "Update quality metrics for an archived frame. Metrics are normally populated automatically after running a quality pipeline (frame_quality for light frames, calibration_quality for dark/bias/flat) via run_pipeline. Use this tool to set or correct them manually. Only supplied fields are updated; omitted fields are unchanged.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID."],
                    "star_count": ["type": "integer", "description": "Number of detected stars (light frames)."],
                    "saturated_star_count": ["type": "integer", "description": "Number of saturated stars (peak ≥ 90 % full-scale)."],
                    "median_fwhm": ["type": "number", "description": "Median FWHM in pixels (average of major and minor axes)."],
                    "background_noise": ["type": "number", "description": "Background level in ADU (light frames, frame_quality pipeline) or noise sigma in ADU (calibration frames, calibration_quality pipeline). Legacy pipelines store a normalised 0–1 value."],
                    "median_eccentricity": ["type": "number", "description": "Median star eccentricity (0=circular, closer to 0 is rounder). Indicates optical quality and tracking accuracy."],
                    "hot_pixel_count": ["type": "integer", "description": "Approximate count of hot pixels (calibration frames, from calibration_quality pipeline)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
    ]

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "archive_add":              return try await archiveAdd(arguments)
        case "archive_get":              return try await archiveGet(arguments)
        case "archive_find":             return try await archiveFind(arguments)
        case "archive_recent":           return try await archiveRecent(arguments)
        case "archive_list_objects":     return try await archiveListObjects()
        case "archive_stats":            return try await archiveStats()
        case "archive_remove":           return try await archiveRemove(arguments)
        case "archive_reject":           return try await archiveReject(arguments)
        case "archive_update_quality":   return try await archiveUpdateQuality(arguments)
        case "archive_frameset_inspect":  return try await archiveFrameSetInspect(arguments)
        case "archive_frameset_create":  return try await archiveFrameSetCreate(arguments)
        case "archive_frameset_list":    return try await archiveFrameSetList()
        case "archive_frameset_get":     return try await archiveFrameSetGet(arguments)
        case "archive_frameset_delete":  return try await archiveFrameSetDelete(arguments)
        default: throw ToolError("Unknown archive tool: \(name)")
        }
    }

    // MARK: - Implementations

    private func makeArchive() throws -> Archive {
        let config = try ArchiveConfiguration.fromEnvironment()
        return try Archive(configuration: config)
    }

    private func archiveAdd(_ args: [String: Any]) async throws -> String {
        guard let path = args["path"] as? String else {
            throw ToolError("archive_add requires 'path'.")
        }
        let recursive = args["recursive"] as? Bool ?? false
        let expanded  = (path as NSString).expandingTildeInPath
        let url       = URL(fileURLWithPath: expanded)

        let archive = try makeArchive()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw ToolError("Path not found: \(path)")
        }

        let added: [ArchivedFrame]
        let skippedCount: Int
        if isDir.boolValue {
            (added, skippedCount) = try await archive.add(directory: url, recursive: recursive)
        } else {
            let (frame, isNew) = try await archive.add(fitsFile: url)
            added = isNew ? [frame] : []
            skippedCount = isNew ? 0 : 1
        }

        var summary = "Added \(added.count) frame(s) to the archive."
        if skippedCount > 0 { summary += " Skipped \(skippedCount) already in archive." }
        var lines = [summary]
        for f in added {
            let filter = f.filter.map { " [\($0)]" } ?? ""
            let exp    = f.exposureTime.map { String(format: " %.0fs", $0) } ?? ""
            let obj    = f.objectName.map { " \($0)" } ?? ""
            lines.append("  \(f.frameType)\(filter)\(exp)\(obj)  \(f.id.uuidString)")
        }
        return lines.joined(separator: "\n")
    }

    private func archiveGet(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_get requires a valid 'id' UUID.")
        }
        let archive = try makeArchive()
        guard let f = try await archive.frame(id: uuid) else {
            throw ToolError("No frame with id \(idStr) found in the archive.")
        }
        let provenance = try await archive.processingRun(for: f)

        let iso = ISO8601DateFormatter()
        func row(_ label: String, _ value: String) -> String {
            String(format: "  %-18@ %@", (label + ":") as NSString, value as NSString)
        }

        var lines: [String] = []
        lines.append("Frame  \(f.id.uuidString)")
        lines.append(String(repeating: "─", count: 60))

        lines.append(row("Type", f.frameType))
        if let v = f.objectName   { lines.append(row("Object",       v)) }
        if let v = f.filter       { lines.append(row("Filter",       v)) }
        if let v = f.exposureTime { lines.append(row("Exposure",     String(format: "%.0f s", v))) }
        if let beg = f.sessionBeg, let end = f.sessionEnd {
            let fmt = { (d: Date) -> String in String(iso.string(from: d).prefix(19)) }
            lines.append(row("Session",      "\(fmt(beg)) → \(fmt(end)) UTC"))
        } else if let v = f.timestamp {
            lines.append(row("Date",         iso.string(from: v)))
        }

        lines.append("")
        var hasCameraSection = false
        if let v = f.camera      { lines.append(row("Camera",       v));                              hasCameraSection = true }
        if let v = f.gain        { lines.append(row("Gain",         String(format: "%.0f", v)));       hasCameraSection = true }
        if let v = f.offset      { lines.append(row("Offset",       String(format: "%.0f", v)));       hasCameraSection = true }
        if let lo = f.temperatureMin, let hi = f.temperatureMax, abs(hi - lo) > 0.05 {
            lines.append(row("Temperature",  String(format: "%.1f … %.1f °C", lo, hi)));    hasCameraSection = true
        } else if let v = f.temperature {
            lines.append(row("Temperature",  String(format: "%.1f °C", v)));                hasCameraSection = true
        }
        if !hasCameraSection     { lines.removeLast() }

        lines.append("")
        var hasOpticsSection = false
        if let ra = f.ra, let dec = f.dec {
            lines.append(row("RA / Dec", String(format: "%.4f° / %.4f°  (J2000)", ra, dec)))
            hasOpticsSection = true
        }
        if let v = f.pixelScale  { lines.append(row("Pixel scale",  String(format: "%.3f \"/px", v))); hasOpticsSection = true }
        if let v = f.focalLength { lines.append(row("Focal length", String(format: "%.0f mm", v)));     hasOpticsSection = true }
        if let w = f.width, let h = f.height {
            let bitStr = f.bitpix.map { "  (\($0)-bit)" } ?? ""
            lines.append(row("Size", "\(w) × \(h)\(bitStr)"))
            hasOpticsSection = true
        }
        if !hasOpticsSection     { lines.removeLast() }

        lines.append("")
        let flags = "calibrated: \(f.calibrated ? "✓" : "✗")  stacked: \(f.stacked ? "✓" : "✗")  stretched: \(f.stretched ? "✓" : "✗")"
        lines.append(row("Processing", "\(f.processingLevel.rawValue)  [\(flags)]"))
        if f.rejected {
            let reasonStr = f.rejectedReason.map { "  (\($0))" } ?? ""
            lines.append(row("Rejected", "yes\(reasonStr)"))
        }

        let hasQuality = f.starCount != nil || f.medianFWHM != nil || f.medianEccentricity != nil
            || f.backgroundNoise != nil || f.saturatedStarCount != nil || f.hotPixelCount != nil
        if hasQuality {
            lines.append("")
            lines.append("Quality metrics")
            lines.append(String(repeating: "─", count: 60))
            if let v = f.starCount          {
                let satStr = f.saturatedStarCount.map { "  (\($0) saturated)" } ?? ""
                lines.append(row("Stars",        "\(v)\(satStr)"))
            }
            if let v = f.medianFWHM         { lines.append(row("FWHM",         String(format: "%.2f px", v))) }
            if let v = f.medianEccentricity { lines.append(row("Eccentricity", String(format: "%.3f", v))) }
            if let v = f.backgroundNoise    { lines.append(row("Bg. noise",    String(format: "%.2f ADU", v))) }
            if let v = f.hotPixelCount      { lines.append(row("Hot pixels",   "\(v)")) }
        }

        lines.append(row("Added at",   iso.string(from: f.addedAt)))
        lines.append(row("File",       f.filePath))

        if let (run, inputs) = provenance {
            lines.append("")
            lines.append("Provenance")
            lines.append(String(repeating: "─", count: 60))
            lines.append(row("Run ID",   run.id.uuidString))
            lines.append(row("Pipeline", run.pipelineID))
            lines.append(row("Run at",   iso.string(from: run.createdAt)))
            if !run.parameters.isEmpty {
                let paramsStr = run.parameters.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
                lines.append(row("Parameters", paramsStr))
            }
            if !inputs.isEmpty {
                lines.append(row("Inputs", ""))
                let grouped = Dictionary(grouping: inputs, by: { $0.inputName })
                for name in grouped.keys.sorted() {
                    let refs = grouped[name]!.sorted { $0.position < $1.position }
                    for ref in refs {
                        let archiveTag = ref.frameID.map { "  [archive: \($0.uuidString)]" } ?? ""
                        let display = ref.filePath ?? "(unknown)"
                        lines.append("    \(name)[\(ref.position)]  \(display)\(archiveTag)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func archiveFind(_ args: [String: Any]) async throws -> String {
        let archive = try makeArchive()

        var query = FrameQuery()
        query.objectName = args["object_name"] as? String
        query.limit      = args["limit"]       as? Int
        query.frameTypes = args["frame_types"] as? [String]
        query.filters    = args["filters"]     as? [String]
        if let lvl = args["processing_level"] as? String {
            query.processingLevel = ProcessingLevel(rawValue: lvl)
        }
        if let cal = args["calibrated"] as? Bool { query.calibrated = cal }
        if let stk = args["stacked"]    as? Bool { query.stacked    = stk }
        if let ra = args["ra"] as? Double,
           let dec = args["dec"] as? Double,
           let r = args["radius_deg"] as? Double {
            query.coneSearch = FrameQuery.ConeSearch(ra: ra, dec: dec, radiusDeg: r)
        }
        if args["rejected_only"] as? Bool == true {
            query.rejectionFilter = .onlyRejected
        } else if args["include_rejected"] as? Bool == true {
            query.rejectionFilter = .includeAll
        }
        query.maxFWHM            = args["max_fwhm"]             as? Double
        query.minStarCount       = args["min_stars"]            as? Int
        query.maxBackgroundNoise = args["max_background_noise"] as? Double
        query.maxEccentricity    = args["max_eccentricity"]     as? Double

        let frames = try await archive.frames(matching: query)
        if frames.isEmpty { return "No frames found matching the query." }

        let iso = ISO8601DateFormatter()
        var lines = ["Found \(frames.count) frame(s):"]
        for f in frames {
            var parts: [String] = [
                "id: \(f.id.uuidString)",
                "type: \(f.frameType)",
            ]
            if let v = f.objectName   { parts.append("object: \(v)") }
            if let v = f.filter       { parts.append("filter: \(v)") }
            if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
            if let v = f.timestamp    { parts.append("date: \(String(iso.string(from: v).prefix(16)).replacingOccurrences(of: "T", with: " "))") }
            parts.append("file: \((f.filePath as NSString).lastPathComponent)")
            lines.append("  { \(parts.joined(separator: ", ")) }")
        }
        return lines.joined(separator: "\n")
    }

    private func archiveRecent(_ args: [String: Any]) async throws -> String {
        let limit   = args["limit"] as? Int ?? 15
        let archive = try makeArchive()
        let frames  = try await archive.recentFrames(limit: limit)
        if frames.isEmpty { return "No frames in archive." }

        let iso = ISO8601DateFormatter()
        func shortDate(_ date: Date) -> String {
            String(iso.string(from: date).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }

        var lines = ["Recently archived frames (\(frames.count)):"]
        for f in frames {
            var parts: [String] = [
                "id: \(f.id.uuidString)",
                "type: \(f.frameType)",
                "added: \(shortDate(f.addedAt))",
            ]
            if let v = f.objectName   { parts.append("object: \(v)") }
            if let v = f.filter       { parts.append("filter: \(v)") }
            if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
            if let v = f.timestamp    { parts.append("date: \(shortDate(v))") }
            parts.append("file: \((f.filePath as NSString).lastPathComponent)")
            lines.append("  { \(parts.joined(separator: ", ")) }")
        }
        return lines.joined(separator: "\n")
    }

    private func archiveListObjects() async throws -> String {
        let archive = try makeArchive()
        let objects = try await archive.listObjects()
        if objects.isEmpty { return "No objects in archive." }
        var lines = ["Objects in archive (\(objects.count)):"]
        for (name, count) in objects {
            lines.append("  \(name): \(count) frame(s)")
        }
        return lines.joined(separator: "\n")
    }

    private func archiveStats() async throws -> String {
        let archive = try makeArchive()
        let stats = try await archive.statistics()

        var lines = [
            "Archive Statistics",
            "  Objects: \(stats.objectCount)",
            "  Frames:  \(stats.frameCount)",
        ]
        if !stats.frameCountByType.isEmpty {
            lines.append("  By type:")
            for (type_, count) in stats.frameCountByType.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(type_): \(count)")
            }
        }
        lines.append("  Used:      \(stats.usedBytesFormatted)")
        lines.append("  Available: \(stats.availableBytesFormatted)")
        return lines.joined(separator: "\n")
    }

    private func archiveReject(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_reject requires a valid 'id' UUID.")
        }
        let undo   = args["undo"] as? Bool ?? false
        let reason = args["reason"] as? String
        let archive = try makeArchive()
        if undo {
            try await archive.unreject(id: uuid)
            return "Frame \(idStr) un-rejected."
        } else {
            try await archive.reject(id: uuid, reason: reason)
            let suffix = reason.map { "  Reason: \($0)" } ?? ""
            return "Frame \(idStr) marked as rejected.\(suffix)"
        }
    }

    // MARK: - Frame set implementations

    private func makeFrameSetQuery(_ args: [String: Any]) -> FrameQuery {
        var query = FrameQuery()
        query.objectName = args["object_name"] as? String
        query.camera     = args["camera"]      as? String
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
        query.maxFWHM            = args["max_fwhm"]             as? Double
        query.minStarCount       = args["min_stars"]            as? Int
        query.maxBackgroundNoise = args["max_background_noise"] as? Double
        query.maxEccentricity    = args["max_eccentricity"]     as? Double
        return query
    }

    private func archiveFrameSetInspect(_ args: [String: Any]) async throws -> String {
        let archive    = try makeArchive()
        let query      = makeFrameSetQuery(args)
        let inspection = try await archive.inspectFrameSet(query: query)
        return inspection.formatted(isDryRun: true)
    }

    private func archiveFrameSetCreate(_ args: [String: Any]) async throws -> String {
        let archive = try makeArchive()
        let query   = makeFrameSetQuery(args)
        let force   = args["force"] as? Bool ?? false

        let objectName = args["object_name"] as? String
        let frameType  = args["frame_type"]  as? String
        let filters    = args["filters"]     as? [String]
        let fromDate   = args["from_date"]   as? String
        let toDate     = args["to_date"]     as? String

        let setName: String
        if let n = args["name"] as? String {
            setName = n
        } else {
            var parts: [String] = []
            if let v = objectName       { parts.append(v) }
            if let v = frameType        { parts.append(v) }
            if let v = filters?.first   { parts.append(v) }
            if let f = fromDate, let t = toDate { parts.append("\(f)–\(t)") }
            setName = parts.isEmpty ? "frameset" : parts.joined(separator: " ")
        }

        let (fs, inspection) = try await archive.createFrameSet(name: setName, query: query, force: force)
        let iso = ISO8601DateFormatter()
        var lines = [
            "Created frame set '\(fs.name)'  [\(fs.id.uuidString)]",
            "",
        ]
        lines.append(inspection.formatted(isDryRun: false))
        lines.append("")
        lines.append("  Created: \(iso.string(from: fs.createdAt))")
        return lines.joined(separator: "\n")
    }

    private func archiveFrameSetList() async throws -> String {
        let archive = try makeArchive()
        let sets = try await archive.frameSets()
        if sets.isEmpty { return "No frame sets in archive." }
        var lines = ["Frame sets (\(sets.count)):"]
        let iso = ISO8601DateFormatter()
        for fs in sets {
            var parts = [
                "id: \(fs.id.uuidString)",
                "name: \(fs.name)",
                "type: \(fs.frameType)",
                "frames: \(fs.frameCount)",
                "level: \(fs.processingLevel.rawValue)",
            ]
            if let v = fs.objectName { parts.append("object: \(v)") }
            if let v = fs.filter     { parts.append("filter: \(v)") }
            parts.append("created: \(String(iso.string(from: fs.createdAt).prefix(16)).replacingOccurrences(of: "T", with: " "))")
            lines.append("  { \(parts.joined(separator: ", ")) }")
        }
        return lines.joined(separator: "\n")
    }

    private func archiveFrameSetGet(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frameset_get requires a valid 'id' UUID.")
        }
        let archive = try makeArchive()
        guard let fs = try await archive.frameSet(id: uuid) else {
            throw ToolError("No frame set with id \(idStr).")
        }
        let memberFrames = try await archive.frames(inFrameSet: uuid)

        let iso = ISO8601DateFormatter()
        func row(_ label: String, _ value: String) -> String {
            String(format: "  %-14@ %@", (label + ":") as NSString, value as NSString)
        }

        var lines: [String] = []
        lines.append("Frame Set  \(fs.id.uuidString)")
        lines.append(String(repeating: "─", count: 60))
        lines.append(row("Name",   fs.name))
        lines.append(row("Type",   fs.frameType))
        lines.append(row("Level",  fs.processingLevel.rawValue))
        lines.append(row("Frames", "\(fs.frameCount)"))
        if let v = fs.objectName   { lines.append(row("Object",   v)) }
        if let v = fs.filter       {
            let label = v.contains(",") ? "Filters" : "Filter"
            lines.append(row(label, v))
        }
        if let v = fs.camera       { lines.append(row("Camera",   v)) }
        if let v = fs.exposureTime { lines.append(row("Exposure", String(format: "%.0f s", v))) }
        if let mn = fs.temperatureMin, let mx = fs.temperatureMax, let mean = fs.temperatureMean {
            if abs(mx - mn) < 0.5 {
                lines.append(row("Temperature", String(format: "%.1f °C", mean)))
            } else {
                lines.append(row("Temperature", String(format: "%.1f – %.1f °C (mean %.1f)", mn, mx, mean)))
            }
        }
        if let v = fs.gain         { lines.append(row("Gain",        String(format: "%.0f", v))) }
        if let v = fs.offset       { lines.append(row("Offset",      String(format: "%.0f", v))) }
        if let w = fs.width, let h = fs.height { lines.append(row("Size", "\(w) × \(h)")) }
        if let v = fs.pixelScale   { lines.append(row("Pixel scale", String(format: "%.3f \"/px", v))) }
        if let v = fs.focalLength  { lines.append(row("Focal length",String(format: "%.0f mm", v))) }
        if let v = fs.positionAngle { lines.append(row("Pos. angle", String(format: "%.1f°", v))) }
        if let from = fs.dateFrom, let to = fs.dateTo {
            let f = String(iso.string(from: from).prefix(10))
            let t = String(iso.string(from: to).prefix(10))
            lines.append(row("Date span", "\(f) – \(t)"))
        }
        lines.append(row("Created", iso.string(from: fs.createdAt)))

        if !memberFrames.isEmpty {
            lines.append("")
            lines.append("Members:")
            for f in memberFrames {
                var parts = ["id: \(f.id.uuidString)", "type: \(f.frameType)"]
                if let v = f.objectName   { parts.append("object: \(v)") }
                if let v = f.filter       { parts.append("filter: \(v)") }
                if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
                if let v = f.timestamp    { parts.append("date: \(String(iso.string(from: v).prefix(16)).replacingOccurrences(of: "T", with: " "))") }
                lines.append("  { \(parts.joined(separator: ", ")) }")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func archiveFrameSetDelete(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frameset_delete requires a valid 'id' UUID.")
        }
        let archive = try makeArchive()
        try await archive.deleteFrameSet(id: uuid)
        return "Deleted frame set \(idStr)."
    }

    private func archiveUpdateQuality(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_update_quality requires a valid 'id' UUID.")
        }
        let starCount          = args["star_count"]           as? Int
        let saturatedStarCount = args["saturated_star_count"] as? Int
        let medianFWHM         = args["median_fwhm"]          as? Double
        let backgroundNoise    = args["background_noise"]     as? Double
        let medianEccentricity = args["median_eccentricity"]  as? Double
        let hotPixelCount      = args["hot_pixel_count"]      as? Int

        guard starCount != nil || saturatedStarCount != nil || medianFWHM != nil
                || backgroundNoise != nil || medianEccentricity != nil || hotPixelCount != nil else {
            throw ToolError(
                "Provide at least one of: star_count, saturated_star_count, median_fwhm, " +
                "background_noise, median_eccentricity, hot_pixel_count."
            )
        }

        let archive = try makeArchive()
        try await archive.updateFrameQuality(
            id: uuid,
            starCount: starCount,
            medianFWHM: medianFWHM,
            backgroundNoise: backgroundNoise,
            medianEccentricity: medianEccentricity,
            saturatedStarCount: saturatedStarCount,
            hotPixelCount: hotPixelCount
        )

        var updated: [String] = []
        if let v = starCount          { updated.append("star_count=\(v)") }
        if let v = saturatedStarCount { updated.append("saturated_star_count=\(v)") }
        if let v = medianFWHM         { updated.append(String(format: "median_fwhm=%.3fpx", v)) }
        if let v = backgroundNoise    { updated.append(String(format: "background_noise=%.2f ADU", v)) }
        if let v = medianEccentricity { updated.append(String(format: "median_eccentricity=%.3f", v)) }
        if let v = hotPixelCount      { updated.append("hot_pixel_count=\(v)") }
        return "Updated quality metrics for frame \(idStr): \(updated.joined(separator: ", "))."
    }

    private func archiveRemove(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_remove requires a valid 'id' UUID.")
        }
        let deleteFile = args["delete_file"] as? Bool ?? false
        let archive = try makeArchive()
        try await archive.remove(id: uuid, deleteFile: deleteFile)
        return "Removed frame \(idStr) from archive.\(deleteFile ? " File deleted." : "")"
    }
}
