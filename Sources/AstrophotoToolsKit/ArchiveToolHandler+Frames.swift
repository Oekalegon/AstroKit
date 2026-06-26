import AstrophotoArchiveKit
import AstrophotoKit
import Foundation

extension ArchiveToolHandler {

    func archiveAdd(_ args: [String: Any]) async throws -> String {
        guard let path = args["path"] as? String else {
            throw ToolError("archive_add requires 'path'.")
        }
        let recursive = args["recursive"] as? Bool ?? false
        let expanded  = (path as NSString).expandingTildeInPath
        let url       = URL(fileURLWithPath: expanded)

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

    func archiveGet(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_get requires a valid 'id' UUID.")
        }
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

        let hasCelestial = f.sunAltitude != nil || f.moonSeparation != nil || f.moonIllumination != nil
        if hasCelestial {
            lines.append("")
            lines.append("Celestial context")
            lines.append(String(repeating: "─", count: 60))
            if let v = f.sunAltitude {
                let label: String
                switch v {
                case let a where a >= 0:   label = "daytime"
                case let a where a >= -6:  label = "civil twilight"
                case let a where a >= -12: label = "nautical twilight"
                case let a where a >= -18: label = "astronomical twilight"
                default:                   label = "astronomical night"
                }
                lines.append(row("Sun altitude", String(format: "%.1f°  (%@)", v, label)))
            }
            if let v = f.moonSeparation  { lines.append(row("Moon sep.",   String(format: "%.1f°", v))) }
            if let v = f.moonIllumination { lines.append(row("Moon phase",  String(format: "%.0f%%", v * 100))) }
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

    func archiveSearch(_ args: [String: Any]) async throws -> String {
        let kindStr = args["kind"] as? String ?? "both"
        let showFrames    = kindStr == "both" || kindStr == "frames"
        let showFrameSets = kindStr == "both" || kindStr == "framesets"

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
            query.telescope  = args["telescope"]   as? String
            query.site       = args["site"]        as? String
            query.gain       = args["gain"]        as? Double
            query.offset     = args["offset"]      as? Double
            query.exposureTimeRange = doubleRange(args, min: "min_exposure",      max: "max_exposure")
            query.isMaster   = args["is_master"]   as? Bool
            if let sidStr = args["session_id"] as? String { query.sessionID = UUID(uuidString: sidStr) }
            query.focalLengthRange  = doubleRange(args, min: "min_focal_length",  max: "max_focal_length")
            query.apertureRange     = doubleRange(args, min: "min_aperture",      max: "max_aperture")
            query.pixelSizeRange    = doubleRange(args, min: "min_pixel_size",    max: "max_pixel_size")
            query.binning    = args["binning"]     as? Int
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
            query.pixelScaleRange    = doubleRange(args, min: "min_pixel_scale",    max: "max_pixel_scale")
            query.widthRange         = intRange(args,    min: "min_width",           max: "max_width")
            query.heightRange        = intRange(args,    min: "min_height",          max: "max_height")
            query.bitpix             = args["bitpix"] as? Int
            query.egainRange         = doubleRange(args, min: "min_egain",           max: "max_egain")
            query.positionAngleRange = doubleRange(args, min: "min_position_angle",  max: "max_position_angle",
                                                   hiOpen: 360.0)
            let df = ymdFormatter
            query.addedAfter  = (args["added_after"]  as? String).flatMap { df.date(from: $0) }
            query.addedBefore = (args["added_before"] as? String).flatMap { df.date(from: $0) }
            query.maxFWHM                = args["max_fwhm"]                as? Double
            query.minStarCount           = args["min_stars"]               as? Int
            query.maxBackgroundNoise     = args["max_background_noise"]    as? Double
            query.maxEccentricity        = args["max_eccentricity"]        as? Double
            query.maxSaturatedStarCount  = args["max_saturated_star_count"] as? Int
            query.maxHotPixelCount       = args["max_hot_pixel_count"]     as? Int
            query.maxSunAltitude         = args["max_sun_altitude"]        as? Double
            query.minMoonSeparation      = args["min_moon_separation"]     as? Double
            query.maxMoonIllumination    = args["max_moon_illumination"]   as? Double

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
            query.telescope  = args["telescope"]   as? String
            query.site       = args["site"]        as? String
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

    func archiveRecent(_ args: [String: Any]) async throws -> String {
        let limitArg = args["limit"] as? Int ?? 15
        let limit: Int? = limitArg > 0 ? limitArg : nil
        let mode = args["mode"] as? String ?? "sessions"

        if mode == "frames" {
            let frames = try await archive.recentFrames(limit: limit)
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
        } else {
            let entries = try await archive.recentActivity(limit: limit)
            if entries.isEmpty { return "No recent activity in archive." }
            return formatRecentActivity(entries)
        }
    }

    func archiveListObjects() async throws -> String {
        let objects = try await archive.listObjects()
        if objects.isEmpty { return "No objects in archive." }
        var lines = ["Objects in archive (\(objects.count)):"]
        for (name, count) in objects {
            lines.append("  \(name): \(count) frame(s)")
        }
        return lines.joined(separator: "\n")
    }

    func archiveStats() async throws -> String {
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
        lines.append("  Total:     \(stats.totalBytesFormatted)")
        return lines.joined(separator: "\n")
    }

    func archiveReject(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_reject requires a valid 'id' UUID.")
        }
        let undo   = args["undo"] as? Bool ?? false
        let reason = args["reason"] as? String
        if undo {
            try await archive.unreject(id: uuid)
            return "Frame \(idStr) un-rejected."
        } else {
            try await archive.reject(id: uuid, reason: reason)
            let suffix = reason.map { "  Reason: \($0)" } ?? ""
            return "Frame \(idStr) marked as rejected.\(suffix)"
        }
    }

    func archiveUpdateQuality(_ args: [String: Any]) async throws -> String {
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

    func archiveUpdateStretch(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_update_stretch requires a valid 'id' UUID.")
        }

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

    func archiveRemove(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_remove requires a valid 'id' UUID.")
        }
        let deleteFile = args["delete_file"] as? Bool ?? false
        try await archive.remove(id: uuid, deleteFile: deleteFile)
        return "Removed frame \(idStr) from archive.\(deleteFile ? " File deleted." : "")"
    }
}
