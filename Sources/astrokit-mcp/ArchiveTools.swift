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
                        "description": "Filters to include (Ha, SII, OIII, R, G, B, L).",
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
    ]

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "archive_add":          return try await archiveAdd(arguments)
        case "archive_get":          return try await archiveGet(arguments)
        case "archive_find":         return try await archiveFind(arguments)
        case "archive_list_objects": return try await archiveListObjects()
        case "archive_stats":        return try await archiveStats()
        case "archive_remove":       return try await archiveRemove(arguments)
        case "archive_reject":       return try await archiveReject(arguments)
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
        if let v = f.timestamp    { lines.append(row("Date",         iso.string(from: v))) }

        lines.append("")
        var hasCameraSection = false
        if let v = f.camera      { lines.append(row("Camera",       v));                              hasCameraSection = true }
        if let v = f.gain        { lines.append(row("Gain",         String(format: "%.0f", v)));       hasCameraSection = true }
        if let v = f.offset      { lines.append(row("Offset",       String(format: "%.0f", v)));       hasCameraSection = true }
        if let v = f.temperature { lines.append(row("Temperature",  String(format: "%.1f °C", v)));    hasCameraSection = true }
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
        lines.append(row("Added at",   iso.string(from: f.addedAt)))
        lines.append(row("File",       f.filePath))

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
            if let v = f.timestamp    { parts.append("date: \(iso.string(from: v).prefix(10))") }
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
