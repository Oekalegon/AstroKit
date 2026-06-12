import AstrophotoKit
import AstrophotoArchiveKit
import AstrophotoToolDefinitions
import Foundation

struct ArchiveTools {

    // MARK: - Tool definitions

    static let definitions: [[String: Any]] = ArchiveToolDefinitions.all

    // MARK: - Quality formatting helpers

    /// Core identification fields for a single frame (level, rejection state), after the basic type/object/filter/exp/date.
    private func frameIdentityParts(_ f: ArchivedFrame) -> [String] {
        var parts: [String] = []
        parts.append("level: \(f.processingLevel.rawValue)")
        if f.rejected { parts.append("rejected: true") }
        return parts
    }

    /// Quality fields for a single frame, ready to append to a parts array.
    private func frameQualityParts(_ f: ArchivedFrame) -> [String] {
        var parts: [String] = []
        if let v = f.starCount          { parts.append("stars: \(v)") }
        if let px = f.medianFWHM {
            if let arcsec = f.medianFWHMArcsec {
                parts.append(String(format: "fwhm: %.2fpx/%.2f\"", px, arcsec))
            } else {
                parts.append(String(format: "fwhm: %.2fpx", px))
            }
        }
        if let v = f.medianEccentricity { parts.append(String(format: "ecc: %.3f", v)) }
        if let e = f.backgroundNoiseElectrons {
            parts.append(String(format: "bg: %.1fe⁻", e))
        } else if let n = f.backgroundNoise {
            parts.append(String(format: "bg: %.1fADU", n))
        }
        if let v = f.saturatedStarCount, v > 0 { parts.append("sat_stars: \(v)") }
        if let v = f.hotPixelCount,      v > 0 { parts.append("hot_px: \(v)") }
        return parts
    }

    /// Quality aggregate fields for a frameset (medians over active members).
    private func frameSetQualityParts(_ fs: ArchivedFrameSet) -> [String] {
        var parts: [String] = []
        if let v = fs.medianStarCount { parts.append(String(format: "med_stars: %.0f", v)) }
        if let px = fs.medianFWHM {
            if let arcsec = fs.medianFWHMArcsec {
                parts.append(String(format: "med_fwhm: %.2fpx/%.2f\"", px, arcsec))
            } else {
                parts.append(String(format: "med_fwhm: %.2fpx", px))
            }
        }
        if let v = fs.medianEccentricity { parts.append(String(format: "med_ecc: %.3f", v)) }
        if let e = fs.medianBackgroundNoiseElectrons {
            parts.append(String(format: "med_bg: %.1fe⁻", e))
        } else if let n = fs.medianBackgroundNoise {
            parts.append(String(format: "med_bg: %.1fADU", n))
        }
        return parts
    }

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Any]) async throws -> String {
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
        case "archive_frameset_exclude":  return try await archiveFrameSetExclude(arguments)
        case "archive_frameset_delete":   return try await archiveFrameSetDelete(arguments)
        case "archive_backfill_metadata": return try await archiveBackfillMetadata(arguments)
        case "archive_set_pixel_scale":   return try await archiveSetPixelScale(arguments)
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
        if let v = f.egain       { lines.append(row("EGAIN",        String(format: "%.4f e⁻/ADU", v))); hasCameraSection = true }
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
            if let v = f.medianFWHM {
                let arcsecStr = f.medianFWHMArcsec.map { String(format: "  (%.2f\")", $0) } ?? ""
                lines.append(row("FWHM", String(format: "%.2f px\(arcsecStr)", v)))
            }
            if let v = f.medianEccentricity { lines.append(row("Eccentricity", String(format: "%.3f", v))) }
            if let v = f.backgroundNoise {
                let eStr = f.backgroundNoiseElectrons.map { String(format: "  (%.2f e⁻)", $0) } ?? ""
                lines.append(row("Bg. noise", String(format: "%.2f ADU\(eStr)", v)))
            }
            if let v = f.hotPixelCount      { lines.append(row("Hot pixels",   "≈\(v)")) }
        }

        let hasStretch = f.stretchSettings.map { !$0.isIdentity } == true
            || f.sliderBlackNorm != nil || f.sliderWhiteNorm != nil
        if hasStretch {
            lines.append("")
            lines.append("Display stretch")
            lines.append(String(repeating: "─", count: 60))
            if let s = f.stretchSettings, !s.isIdentity {
                lines.append(row("Norm black", String(format: "%.4f", s.inputBlack)))
                lines.append(row("Norm white", String(format: "%.4f", s.inputWhite)))
            }
            if let v = f.sliderBlackNorm { lines.append(row("Slider black", String(format: "%.4f", v))) }
            if let v = f.sliderWhiteNorm { lines.append(row("Slider white", String(format: "%.4f", v))) }
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

    private func archiveSearch(_ args: [String: Any]) async throws -> String {
        let kindStr = args["kind"] as? String ?? "both"
        let showFrames    = kindStr == "both" || kindStr == "frames"
        let showFrameSets = kindStr == "both" || kindStr == "framesets"
        let archive = try makeArchive()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        let dateRange: DateInterval? = {
            guard let fromStr = args["from_date"] as? String,
                  let toStr   = args["to_date"]   as? String,
                  let fromDate = df.date(from: fromStr),
                  let toDate   = df.date(from: toStr) else { return nil }
            return DateInterval(start: fromDate, end: toDate)
        }()

        let iso = ISO8601DateFormatter()
        func shortDate(_ d: Date) -> String {
            String(iso.string(from: d).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }

        var lines: [String] = []

        if showFrames {
            var query = FrameQuery()
            query.objectName = args["object_name"] as? String
            query.camera     = args["camera"]      as? String
            query.limit      = args["limit"]       as? Int
            query.frameTypes = args["frame_types"] as? [String]
            query.filters    = args["filters"]     as? [String]
            if let lvl = args["processing_level"] as? String { query.processingLevel = ProcessingLevel(rawValue: lvl) }
            if args["stacked"] as? Bool == true { query.stacked = true }
            query.dateRange  = dateRange
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
            lines.append("Frames (\(frames.count)):")
            if frames.isEmpty {
                lines.append("  (none)")
            } else {
                for f in frames {
                    var parts: [String] = ["id: \(f.id.uuidString)", "type: \(f.frameType)"]
                    if let v = f.objectName   { parts.append("object: \(v)") }
                    if let v = f.filter       { parts.append("filter: \(v)") }
                    if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
                    if let v = f.timestamp    { parts.append("date: \(shortDate(v))") }
                    parts += frameIdentityParts(f)
                    parts += frameQualityParts(f)
                    parts.append("file: \(f.filePath)")
                    lines.append("  { \(parts.joined(separator: ", ")) }")
                }
            }
        }

        if showFrameSets {
            if !lines.isEmpty { lines.append("") }
            var query = FrameSetQuery()
            query.name       = args["name"]        as? String
            query.objectName = args["object_name"] as? String
            query.camera     = args["camera"]      as? String
            query.frameTypes = args["frame_types"] as? [String]
            query.filters    = args["filters"]     as? [String]
            if let lvl = args["processing_level"] as? String { query.processingLevel = ProcessingLevel(rawValue: lvl) }
            query.dateRange  = dateRange

            let sets = try await archive.frameSets(matching: query)
            lines.append("Frame Sets (\(sets.count)):")
            if sets.isEmpty {
                lines.append("  (none)")
            } else {
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
                    parts += frameSetQualityParts(fs)
                    parts.append("created: \(shortDate(fs.createdAt))")
                    lines.append("  { \(parts.joined(separator: ", ")) }")
                }
            }
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
            parts += frameIdentityParts(f)
            parts += frameQualityParts(f)
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

    private func archiveBackfillMetadata(_ args: [String: Any]) async throws -> String {
        let includeStacked = args["include_stacked"] as? Bool ?? false
        let archive = try makeArchive()
        // .stretched is omitted: no code path currently writes the STRETCHD FITS keyword,
        // so stretched frames cannot exist in archives produced by this toolchain.
        let levels: [ProcessingLevel] = includeStacked
            ? [.raw, .calibrated, .stacked]
            : [.raw]
        let result = try await archive.backfillObservationMetadata(processingLevels: levels)
        var lines = [
            "Backfilled observation metadata:",
            "  Updated:          \(result.updated)",
            "  Skipped:          \(result.skipped)",
        ]
        if result.frameSetsUpdated > 0 {
            lines.append("  Framesets (pixel scale): \(result.frameSetsUpdated)")
        }
        if result.failed > 0 {
            lines.append("  Failed (unreadable): \(result.failed)")
            lines += result.failedPaths.map { "    \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    private func archiveSetPixelScale(_ args: [String: Any]) async throws -> String {
        let telescope = args["telescope"] as? String
        let camera    = args["camera"]    as? String
        let overwrite = args["overwrite"] as? Bool ?? false

        let scale: Double
        if let explicit = args["arcsec_per_pixel"] as? Double {
            scale = explicit
        } else if let fl = args["focal_length_mm"] as? Double,
                  let px = args["pixel_size_um"] as? Double {
            let binning = (args["binning"] as? Int) ?? 1
            guard let computed = PixelScale.arcsecPerPixel(
                pixelSizeMicrons: px, binning: binning, focalLengthMm: fl
            ) else {
                throw ToolError("focal_length_mm, pixel_size_um, and binning must all be positive.")
            }
            scale = computed
        } else {
            throw ToolError("archive_set_pixel_scale requires 'arcsec_per_pixel', or 'focal_length_mm' + 'pixel_size_um'.")
        }

        let archive = try makeArchive()
        let (frames, frameSets) = try await archive.setPixelScale(
            scale, telescope: telescope, camera: camera, overwrite: overwrite
        )
        let scope = [telescope.map { "telescope: \($0)" }, camera.map { "camera: \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        return String(
            format: "Set pixel scale %.4f\"/px (%@):\n  Frames updated:    %d\n  Framesets updated: %d",
            scale, scope, frames, frameSets
        )
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
        // minStars and maxBackgroundNoise are hard query filters.
        // maxFWHM and maxEccentricity are exclusion thresholds passed separately to createFrameSet/inspectFrameSet.
        query.minStarCount       = args["min_stars"]            as? Int
        query.maxBackgroundNoise = args["max_background_noise"] as? Double
        return query
    }

    private func archiveFrameSetInspect(_ args: [String: Any]) async throws -> String {
        let archive         = try makeArchive()
        let query           = makeFrameSetQuery(args)
        let maxFWHM         = args["max_fwhm"]         as? Double
        let maxEccentricity = args["max_eccentricity"] as? Double
        let inspection = try await archive.inspectFrameSet(
            query: query,
            maxFWHM: maxFWHM,
            maxEccentricity: maxEccentricity
        )
        return inspection.formatted(isDryRun: true)
    }

    private func archiveFrameSetCreate(_ args: [String: Any]) async throws -> String {
        guard args["frame_type"] is String else {
            throw ToolError("frame_type is required for frameset creation (e.g. \"light\").")
        }
        let archive         = try makeArchive()
        let query           = makeFrameSetQuery(args)
        let force           = args["force"] as? Bool ?? false
        let maxFWHM         = args["max_fwhm"]         as? Double
        let maxEccentricity = args["max_eccentricity"] as? Double

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

        let (fs, inspection) = try await archive.createFrameSet(
            name: setName,
            query: query,
            force: force,
            maxFWHM: maxFWHM,
            maxEccentricity: maxEccentricity
        )
        let iso = ISO8601DateFormatter()
        var lines = [
            "Created frame set '\(fs.name)'  [\(fs.id.uuidString)]",
            "",
        ]
        if fs.excludedFrameCount > 0 {
            lines.append("  \(fs.excludedFrameCount) frame(s) included but excluded by quality threshold.")
        }
        lines.append(inspection.formatted(isDryRun: false))
        lines.append("")
        lines.append("  Created: \(iso.string(from: fs.createdAt))")
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
        let members = try await archive.members(inFrameSet: uuid)

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
        let framesSuffix = fs.excludedFrameCount > 0 ? " (\(fs.excludedFrameCount) excluded)" : ""
        lines.append(row("Frames", "\(fs.frameCount)\(framesSuffix)"))
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

        let fsQuality = frameSetQualityParts(fs)
        if !fsQuality.isEmpty {
            lines.append("")
            lines.append("Quality (medians over active frames):")
            for part in fsQuality { lines.append("  \(part)") }
        }

        if !members.isEmpty {
            lines.append("")
            lines.append("Members:")
            for m in members {
                let f = m.frame
                var parts = ["id: \(f.id.uuidString)", "type: \(f.frameType)"]
                if m.excluded { parts.append("excluded: true") }
                if let r = m.excludedReason { parts.append("reason: \(r)") }
                if let v = f.objectName   { parts.append("object: \(v)") }
                if let v = f.filter       { parts.append("filter: \(v)") }
                if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
                if let v = f.timestamp    { parts.append("date: \(String(iso.string(from: v).prefix(16)).replacingOccurrences(of: "T", with: " "))") }
                parts += frameIdentityParts(f)
                parts += frameQualityParts(f)
                parts.append("file: \(f.filePath)")
                lines.append("  { \(parts.joined(separator: ", ")) }")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func archiveFrameSetQuality(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frameset_quality requires a valid 'id' UUID.")
        }
        let archive = try makeArchive()
        guard let fs = try await archive.frameSet(id: uuid) else {
            throw ToolError("No frame set with id \(idStr).")
        }
        let members = try await archive.members(inFrameSet: uuid)
        guard !members.isEmpty else { return "Frame set '\(fs.name)' has no frames." }

        let iso = ISO8601DateFormatter()
        let hasQuality = members.contains { $0.frame.starCount != nil || $0.frame.medianFWHM != nil }

        var lines: [String] = []
        let excludedSuffix = fs.excludedFrameCount > 0 ? ", \(fs.excludedFrameCount) excluded" : ""
        lines.append("Frame Set: \(fs.name)  [\(fs.id.uuidString)]")
        lines.append("Frames: \(members.count)\(excludedSuffix)")

        if !hasQuality {
            lines.append("")
            lines.append("No quality data available for this frameset.")
            lines.append("Run: ap-archive frameset quality \(fs.id.uuidString)")
            lines.append("  or: ap run frame_quality --input @frameset:\(fs.id.uuidString)")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        var table = TextTable(columns: [
            .init("ID"),
            .init("Object"),
            .init("Filter"),
            .init("Exposure", .right),
            .init("Stars", .right),
            .init("FWHM", .right),
            .init("Ecc", .right),
            .init("Background", .right),
            .init("Date"),
        ])
        for m in members {
            let f = m.frame
            let obj  = f.objectName ?? "-"
            let filt = f.filter ?? "-"
            let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
            let stars = f.starCount.map { "\($0)" } ?? "-"
            let fwhm: String
            if let px = f.medianFWHM {
                fwhm = f.medianFWHMArcsec.map { String(format: "%.2fpx/%.2f\"", px, $0) }
                    ?? String(format: "%.2fpx", px)
            } else { fwhm = "-" }
            let ecc = f.medianEccentricity.map { String(format: "%.3f", $0) } ?? "-"
            let bg: String
            if let e = f.backgroundNoiseElectrons {
                bg = String(format: "%.1fe⁻", e)
            } else if let n = f.backgroundNoise {
                bg = String(format: "%.1fADU", n)
            } else { bg = "-" }
            let date = f.timestamp.map {
                String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ")
            } ?? "-"
            let excludeFlag = m.excluded ? "* " : ""
            table.addRow([excludeFlag + f.id.uuidString, obj, filt, exp, stars, fwhm, ecc, bg, date])
        }
        lines.append(table.render())

        // Summary statistics over active (non-excluded) frames.
        let active = members.filter { !$0.excluded }.map { $0.frame }
        let fwhmValues = active.compactMap { $0.medianFWHM }
        let eccValues  = active.compactMap { $0.medianEccentricity }
        if !fwhmValues.isEmpty || !eccValues.isEmpty {
            lines.append("Active frames (\(active.count)):")
            if !fwhmValues.isEmpty {
                let med = medianValue(fwhmValues)
                if let scale = active.compactMap({ $0.pixelScale }).first {
                    lines.append(String(format: "  Median FWHM:         %.2fpx / %.2f\"", med, med * scale))
                } else {
                    lines.append(String(format: "  Median FWHM:         %.2fpx", med))
                }
            }
            if !eccValues.isEmpty {
                lines.append(String(format: "  Median eccentricity: %.3f", medianValue(eccValues)))
            }
        }
        if fs.excludedFrameCount > 0 {
            lines.append("(* = excluded from frameset)")
        }
        return lines.joined(separator: "\n")
    }

    private func medianValue(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 0
            ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
            : sorted[n / 2]
    }

    private func archiveFrameSetExclude(_ args: [String: Any]) async throws -> String {
        guard let setStr = args["frameset_id"] as? String, let setUUID = UUID(uuidString: setStr) else {
            throw ToolError("archive_frameset_exclude requires a valid 'frameset_id' UUID.")
        }
        guard let frmStr = args["frame_id"] as? String, let frmUUID = UUID(uuidString: frmStr) else {
            throw ToolError("archive_frameset_exclude requires a valid 'frame_id' UUID.")
        }
        let undo   = args["undo"] as? Bool ?? false
        let reason = args["reason"] as? String
        let archive = try makeArchive()
        try await archive.setMemberExcluded(
            frameSetID: setUUID, frameID: frmUUID,
            excluded: !undo, reason: undo ? nil : reason
        )
        if undo {
            return "Frame \(frmStr) re-included in frame set \(setStr)."
        } else {
            let suffix = reason.map { ": \($0)" } ?? ""
            return "Frame \(frmStr) marked as excluded in frame set \(setStr)\(suffix)."
        }
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

    private func archiveUpdateStretch(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_update_stretch requires a valid 'id' UUID.")
        }
        let archive = try makeArchive()

        if args["reset"] as? Bool == true {
            try await archive.updateStretchSettings(nil, sliderBlackNorm: nil, sliderWhiteNorm: nil, id: uuid)
            return "Cleared stretch and slider state for frame \(idStr) — reverted to identity (full range)."
        }

        let inputBlack  = args["input_black"]  as? Double
        let inputWhite  = args["input_white"]  as? Double
        let sliderBlack = args["slider_black"] as? Double
        let sliderWhite = args["slider_white"] as? Double

        guard inputBlack != nil || inputWhite != nil || sliderBlack != nil || sliderWhite != nil else {
            throw ToolError(
                "Provide at least one of: input_black, input_white, slider_black, slider_white; or pass reset: true."
            )
        }

        var settings: StretchSettings? = nil
        if let ib = inputBlack, let iw = inputWhite {
            let b = Float(ib), w = Float(iw)
            guard b < w   else { throw ToolError("input_black (\(b)) must be less than input_white (\(w)).") }
            guard b >= 0, w <= 1 else { throw ToolError("input_black and input_white must be in [0, 1].") }
            settings = StretchSettings(inputBlack: b, inputWhite: w)
        }

        let sbNorm = sliderBlack.map { Float($0) }
        let swNorm = sliderWhite.map { Float($0) }
        if let sb = sbNorm, let sw = swNorm {
            guard sb <= sw else { throw ToolError("slider_black (\(sb)) must be ≤ slider_white (\(sw)).") }
            guard sb >= 0, sw <= 1 else { throw ToolError("slider_black and slider_white must be in [0, 1].") }
        }

        try await archive.updateStretchSettings(settings, sliderBlackNorm: sbNorm, sliderWhiteNorm: swNorm, id: uuid)

        var parts: [String] = []
        if let s = settings { parts.append(String(format: "norm=[%.4f, %.4f]", s.inputBlack, s.inputWhite)) }
        if let v = sbNorm   { parts.append(String(format: "slider_black=%.4f", v)) }
        if let v = swNorm   { parts.append(String(format: "slider_white=%.4f", v)) }
        return "Saved stretch for frame \(idStr): \(parts.joined(separator: "  "))"
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
