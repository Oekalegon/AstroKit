import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Frameset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frameset",
        abstract: "Manage frame sets.",
        subcommands: [Create.self, List.self, Show.self, Delete.self]
    )

    // MARK: - Shared query options

    struct QueryOptions: ParsableArguments {
        @Option(name: .long, help: "Frame type (light, dark, flat, bias).")
        var type: String?

        @Option(name: .long, help: "Filter by object name (partial match).")
        var object: String?

        @Option(name: .long, help: "Optical filter (Hɑ, SII, OIII, R, G, B, L).")
        var filter: String?

        @Option(name: .long, help: "Camera name (exact match).")
        var camera: String?

        @Option(name: .long, help: "Start date (YYYY-MM-DD).")
        var from: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD).")
        var to: String?

        @Option(name: .long, help: "Processing level (raw, calibrated, stacked, stretched).")
        var level: String?

        @Flag(name: .long, help: "Only calibrated frames.")
        var calibrated: Bool = false

        @Option(name: .long, help: "Centre temperature for dark frame grouping (°C).")
        var tempCenter: Double?

        @Option(name: .long, help: "Temperature tolerance ±°C for dark grouping (default 2.0).")
        var tempTolerance: Double?

        @Option(name: .long, help: "Only include frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded.")
        var maxFwhm: Double?

        @Option(name: .long, help: "Only include frames with at least this many detected stars. Frames without quality data are excluded.")
        var minStars: Int?

        @Option(name: .long, help: "Only include frames with background noise ≤ this value (0–1). Frames without quality data are excluded.")
        var maxBackgroundNoise: Double?

        func makeQuery() -> FrameQuery {
            var query = FrameQuery()
            query.objectName = object
            query.camera = camera
            if let t = type   { query.frameTypes = [t] }
            if let f = filter { query.filters    = [f] }
            if let lvl = level { query.processingLevel = ProcessingLevel(rawValue: lvl) }
            if calibrated { query.calibrated = true }
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "UTC")
            if let fromStr = from, let toStr = to,
               let fromDate = df.date(from: fromStr), let toDate = df.date(from: toStr) {
                query.dateRange = DateInterval(start: fromDate, end: toDate)
            }
            if let center = tempCenter {
                let tol = tempTolerance ?? 2.0
                query.temperatureRange = (center - tol)...(center + tol)
            }
            query.maxFWHM            = maxFwhm
            query.minStarCount       = minStars
            query.maxBackgroundNoise = maxBackgroundNoise
            return query
        }
    }

    // MARK: - Create

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a frame set from frames matching a query. Pass --dry-run to preview without creating."
        )

        @OptionGroup var archiveOptions: ArchivePathOption
        @OptionGroup var queryOptions: QueryOptions

        @Option(name: .long, help: "Name for the frame set (auto-generated if omitted).")
        var name: String?

        @Flag(name: .long, help: "Allow mixed optical filters; stores them as a comma-separated list.")
        var force: Bool = false

        @Flag(name: .long, help: "Show the inspection report without creating the frame set.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)
            let query   = queryOptions.makeQuery()
            let hasQualityFilter = queryOptions.maxFwhm != nil
                || queryOptions.minStars != nil
                || queryOptions.maxBackgroundNoise != nil

            if dryRun {
                let inspection = try await archive.inspectFrameSet(query: query)
                if !json {
                    try await printRejectedWarnings(archive: archive, inspection: inspection, query: query)
                    if hasQualityFilter {
                        try await printMissingQualityWarnings(archive: archive, inspection: inspection)
                    }
                }
                if json {
                    printInspectionJSON(inspection)
                } else {
                    print(inspection.formatted(isDryRun: true))
                }
                return
            }

            let setName = name ?? autoName(queryOptions)
            let (frameSet, inspection) = try await archive.createFrameSet(
                name: setName, query: query, force: force
            )

            if json {
                printJSON(frameSet, inspection: inspection)
            } else {
                try await printRejectedWarnings(archive: archive, inspection: inspection, query: query)
                if hasQualityFilter {
                    try await printMissingQualityWarnings(archive: archive, inspection: inspection)
                }
                print("Created frame set '\(frameSet.name)'  [\(frameSet.id.uuidString)]")
                print("")
                print(inspection.formatted(isDryRun: false))
            }
        }

        /// Queries for rejected frames that pass every other filter and prints an orange warning.
        /// A frame appears here only if it would be in the frameset were it not rejected —
        /// i.e., it satisfies the type, object, filter, date, quality, and all other criteria.
        private func printRejectedWarnings(
            archive: Archive,
            inspection: FrameSetInspection,
            query: FrameQuery
        ) async throws {
            // Same query as the main one but lift the rejection exclusion.
            var rejQuery = query
            rejQuery.rejectionFilter = .includeAll
            let allFrames   = try await archive.frames(matching: rejQuery)
            let includedIDs = Set(inspection.frames.map { $0.id })

            let rejected = allFrames.filter { $0.rejected && !includedIDs.contains($0.id) }
            guard !rejected.isEmpty else { return }

            let n    = rejected.count
            let noun = n == 1 ? "frame" : "frames"
            let verb = n == 1 ? "was"   : "were"
            print(orangeText("⚠  \(n) \(noun) matched the query but \(verb) excluded because \(n == 1 ? "it is" : "they are") rejected:"))
            for f in rejected.prefix(5) {
                let filename  = (f.filePath as NSString).lastPathComponent
                let reasonStr = f.rejectedReason.map { " — \($0)" } ?? ""
                print(orangeText("   \(filename)\(reasonStr)"))
            }
            if rejected.count > 5 {
                print(orangeText("   …and \(rejected.count - 5) more"))
            }
            print(orangeText("   Use 'ap-archive reject <id> --undo' to un-reject a frame."))
            print("")
        }

        /// Queries for all frames that match the base criteria (ignoring quality filters) and
        /// prints an orange warning for any that were excluded solely because quality data is absent.
        private func printMissingQualityWarnings(
            archive: Archive,
            inspection: FrameSetInspection
        ) async throws {
            // Re-run the query without quality filters to find every candidate frame.
            var baseQuery = queryOptions.makeQuery()
            baseQuery.maxFWHM            = nil
            baseQuery.minStarCount       = nil
            baseQuery.maxBackgroundNoise = nil
            let allFrames   = try await archive.frames(matching: baseQuery)
            let includedIDs = Set(inspection.frames.map { $0.id })

            // A frame is "missing quality data" if it is not included in the quality-filtered
            // result AND has a nil value for at least one of the active filter fields.
            let excluded = allFrames.filter { f in
                !includedIDs.contains(f.id) &&
                ((queryOptions.maxFwhm != nil            && f.medianFWHM      == nil) ||
                 (queryOptions.minStars != nil           && f.starCount        == nil) ||
                 (queryOptions.maxBackgroundNoise != nil && f.backgroundNoise  == nil))
            }
            guard !excluded.isEmpty else { return }

            let n = excluded.count
            let noun = n == 1 ? "frame" : "frames"
            let verb = n == 1 ? "was"   : "were"
            print(orangeText("⚠  \(n) \(noun) matched the query but \(verb) excluded — no quality data for the active filter(s):"))
            for f in excluded.prefix(5) {
                var missing: [String] = []
                if queryOptions.maxFwhm != nil            && f.medianFWHM     == nil { missing.append("FWHM") }
                if queryOptions.minStars != nil           && f.starCount       == nil { missing.append("star count") }
                if queryOptions.maxBackgroundNoise != nil && f.backgroundNoise == nil { missing.append("bg. noise") }
                let filename = (f.filePath as NSString).lastPathComponent
                print(orangeText("   \(filename)  (no \(missing.joined(separator: ", ")))"))
            }
            if excluded.count > 5 {
                print(orangeText("   …and \(excluded.count - 5) more"))
            }
            print(orangeText("   Tip: run 'ap run star_detection --input <file>' to populate quality metrics."))
            print("")
        }

        private func autoName(_ q: QueryOptions) -> String {
            var parts: [String] = []
            if let v = q.object { parts.append(v) }
            if let v = q.type   { parts.append(v) }
            if let v = q.filter { parts.append(v) }
            if let f = q.from, let t = q.to { parts.append("\(f)–\(t)") }
            if let v = q.maxFwhm            { parts.append(String(format: "FWHM<%.1fpx", v)) }
            if let v = q.minStars           { parts.append("stars≥\(v)") }
            if let v = q.maxBackgroundNoise { parts.append(String(format: "noise<%.4f", v)) }
            return parts.isEmpty ? "frameset" : parts.joined(separator: " ")
        }

        private func printJSON(_ fs: ArchivedFrameSet, inspection: FrameSetInspection) {
            let iso = ISO8601DateFormatter()
            var d = frameSetDict(fs, iso: iso)
            d["inspection"] = inspectionDict(inspection, iso: iso)
            writeJSON(d)
        }

        private func printInspectionJSON(_ inspection: FrameSetInspection) {
            let iso = ISO8601DateFormatter()
            writeJSON(inspectionDict(inspection, iso: iso))
        }
    }

    // MARK: - List

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all frame sets."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Flag(name: .long, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)
            let sets = try await archive.frameSets()

            if sets.isEmpty {
                print("No frame sets in archive.")
                return
            }

            if json {
                let iso = ISO8601DateFormatter()
                let arr = sets.map { frameSetDict($0, iso: iso) }
                writeJSON(arr)
                return
            }

            print("Frame sets (\(sets.count)):\n")
            let header = String(format: "%-36@  %-5@  %-8@  %-12@  %-8@  %@",
                "ID" as NSString, "Count" as NSString, "Type" as NSString,
                "Level" as NSString, "Filter" as NSString, "Name" as NSString)
            print(header)
            print(String(repeating: "-", count: header.count))
            for fs in sets {
                let filterLabel: String
                if let f = fs.filter {
                    filterLabel = f.count > 8 ? String(f.prefix(7)) + "…" : f
                } else {
                    filterLabel = "-"
                }
                print(String(format: "%-36@  %-5d  %-8@  %-12@  %-8@  %@",
                    fs.id.uuidString as NSString,
                    fs.frameCount,
                    fs.frameType as NSString,
                    fs.processingLevel.rawValue as NSString,
                    filterLabel as NSString,
                    fs.name as NSString))
            }
        }
    }

    // MARK: - Show

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show details of a frame set, including its member frames."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID.")
        var id: String

        @Flag(name: .long, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                printError("Invalid UUID: \(id)")
                throw ExitCode.failure
            }
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)

            guard let fs = try await archive.frameSet(id: uuid) else {
                printError("No frame set with id \(id).")
                throw ExitCode.failure
            }
            let memberFrames = try await archive.frames(inFrameSet: uuid)

            if json {
                let iso = ISO8601DateFormatter()
                var d = frameSetDict(fs, iso: iso)
                d["members"] = memberFrames.map { frameBriefDict($0, iso: iso) }
                writeJSON(d)
            } else {
                printTable(fs, frames: memberFrames)
            }
        }

        private func printTable(_ fs: ArchivedFrameSet, frames: [ArchivedFrame]) {
            let iso = ISO8601DateFormatter()
            func row(_ label: String, _ value: String) {
                print(String(format: "  %-14@ %@", (label + ":") as NSString, value as NSString))
            }

            print("Frame Set  \(fs.id.uuidString)")
            print(String(repeating: "─", count: 60))
            row("Name",   fs.name)
            row("Type",   fs.frameType)
            row("Level",  fs.processingLevel.rawValue)
            row("Frames", "\(fs.frameCount)")
            if let v = fs.objectName    { row("Object",   v) }
            if let v = fs.filter {
                let label = v.contains(",") ? "Filters" : "Filter"
                row(label, v)
            }
            if let v = fs.camera        { row("Camera",   v) }
            if let v = fs.exposureTime  { row("Exposure", String(format: "%.0f s", v)) }
            if let mn = fs.temperatureMin, let mx = fs.temperatureMax {
                if abs(mx - mn) < 0.5 {
                    row("Temperature", String(format: "%.1f °C", fs.temperatureMean ?? mn))
                } else {
                    row("Temperature", String(format: "%.1f – %.1f °C", mn, mx))
                }
            }
            if let v = fs.gain          { row("Gain",     String(format: "%.0f", v)) }
            if let w = fs.width, let h = fs.height { row("Size", "\(w) × \(h)") }
            if let v = fs.pixelScale    { row("Pixel scale", String(format: "%.3f \"/px", v)) }
            if let v = fs.focalLength   { row("Focal length", String(format: "%.0f mm", v)) }
            if let v = fs.positionAngle { row("Pos. angle", String(format: "%.1f°", v)) }
            if let from = fs.dateFrom, let to = fs.dateTo {
                let f = String(iso.string(from: from).prefix(10))
                let t = String(iso.string(from: to).prefix(10))
                row("Date span", "\(f) – \(t)")
            }
            row("Created", iso.string(from: fs.createdAt))

            if !frames.isEmpty {
                func memberRow(_ uuid: String, _ obj: String, _ filt: String,
                               _ exp: String, _ date: String) {
                    print(String(format: "  %-36@  %-14@  %-8@  %8@  %@",
                        uuid as NSString, obj as NSString, filt as NSString,
                        exp as NSString, date as NSString))
                }
                print("")
                print("Members (\(frames.count)):")
                memberRow("UUID", "Object", "Filter", "Exposure", "Date")
                print("  " + String(repeating: "─", count: 36 + 14 + 8 + 8 + 16))
                for f in frames {
                    let obj  = f.objectName ?? "-"
                    let filt = f.filter ?? "-"
                    let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                    let date = f.timestamp.map { String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "-"
                    memberRow(f.id.uuidString, obj, filt, exp, date)
                }
            }
        }
    }

    // MARK: - Delete

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a frame set. Member frames are not removed from the archive."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID.")
        var id: String

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                printError("Invalid UUID: \(id)")
                throw ExitCode.failure
            }
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)
            try await archive.deleteFrameSet(id: uuid)
            print("Deleted frame set \(id).")
        }
    }
}

// MARK: - Shared JSON helpers (file-private, used by all subcommands)

private func frameSetDict(_ fs: ArchivedFrameSet, iso: ISO8601DateFormatter) -> [String: Any] {
    var d: [String: Any] = [
        "id": fs.id.uuidString,
        "name": fs.name,
        "frame_type": fs.frameType,
        "processing_level": fs.processingLevel.rawValue,
        "frame_count": fs.frameCount,
        "created_at": iso.string(from: fs.createdAt),
    ]
    if let v = fs.objectName    { d["object_name"]    = v }
    if let v = fs.filter        { d["filter"]          = v }
    if let v = fs.camera        { d["camera"]          = v }
    if let v = fs.exposureTime  { d["exposure_time"]   = v }
    if let v = fs.temperatureMean { d["temperature_mean"] = v }
    if let v = fs.temperatureMin  { d["temperature_min"]  = v }
    if let v = fs.temperatureMax  { d["temperature_max"]  = v }
    if let v = fs.gain          { d["gain"]            = v }
    if let v = fs.offset        { d["offset"]          = v }
    if let v = fs.width         { d["width"]           = v }
    if let v = fs.height        { d["height"]          = v }
    if let v = fs.pixelScale    { d["pixel_scale"]     = v }
    if let v = fs.focalLength   { d["focal_length"]    = v }
    if let v = fs.positionAngle { d["position_angle"]  = v }
    if let v = fs.dateFrom      { d["date_from"] = iso.string(from: v) }
    if let v = fs.dateTo        { d["date_to"]   = iso.string(from: v) }
    return d
}

private func inspectionDict(_ inspection: FrameSetInspection, iso: ISO8601DateFormatter) -> [String: Any] {
    func entries(_ e: [FrameSetInspection.Entry]) -> [[String: Any]] {
        e.map { ["label": $0.label, "count": $0.count] }
    }
    var d: [String: Any] = [
        "matched_frame_count": inspection.matchedFrameCount,
        "frame_types":       entries(inspection.frameTypes),
        "filters":           entries(inspection.filters),
        "processing_levels": entries(inspection.processingLevels),
        "object_names":      entries(inspection.objectNames),
        "cameras":           entries(inspection.cameras),
        "pixel_scales":      entries(inspection.pixelScales),
        "focal_lengths":     entries(inspection.focalLengths),
        "position_angles":   entries(inspection.positionAngles),
        "can_create":        inspection.canCreate,
        "needs_force":       inspection.needsForce,
        "issues":            inspection.issues,
    ]
    if let v = inspection.dateFrom      { d["date_from"]         = iso.string(from: v) }
    if let v = inspection.dateTo        { d["date_to"]           = iso.string(from: v) }
    if let v = inspection.temperatureMin  { d["temperature_min"]  = v }
    if let v = inspection.temperatureMax  { d["temperature_max"]  = v }
    if let v = inspection.temperatureMean { d["temperature_mean"] = v }
    return d
}

private func frameBriefDict(_ f: ArchivedFrame, iso: ISO8601DateFormatter) -> [String: Any] {
    var d: [String: Any] = ["id": f.id.uuidString, "frame_type": f.frameType, "file_path": f.filePath]
    if let v = f.objectName   { d["object_name"]  = v }
    if let v = f.filter       { d["filter"]       = v }
    if let v = f.exposureTime { d["exposure_time"] = v }
    if let v = f.timestamp    { d["timestamp"]    = iso.string(from: v) }
    return d
}

private func writeJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
       let str = String(data: data, encoding: .utf8) { print(str) }
}
