import ArgumentParser
import AstrophotoArchiveKit
import Darwin
import Foundation

struct Frameset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frameset",
        abstract: "Manage frame sets.",
        subcommands: [Create.self, Show.self, Quality.self, Add.self, Remove.self,
                      Exclude.self, Include.self, Delete.self]
    )

    // MARK: - Shared query options

    struct QueryOptions: ParsableArguments {
        @Option(name: .long, help: "Frame type (light, dark, flat, bias, diagnostic).")
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

        @Option(name: .long, help: "Only include frames with mean star eccentricity ≤ this value (0=circular). Frames without quality data are excluded.")
        var maxEccentricity: Double?

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
            // maxFwhm and maxEccentricity are NOT added to the query for frameset creation —
            // they become per-member exclusion thresholds instead (include-but-exclude semantics).
            // They ARE still added here so the same QueryOptions can be used for general queries.
            query.maxFWHM            = maxFwhm
            query.minStarCount       = minStars
            query.maxBackgroundNoise = maxBackgroundNoise
            query.maxEccentricity    = maxEccentricity
            return query
        }

        /// Query without FWHM/eccentricity filters — used for frameset creation where those
        /// thresholds are applied as per-member exclusion flags rather than hard filters.
        func makeBaseQuery() -> FrameQuery {
            var q = makeQuery()
            q.maxFWHM         = nil
            q.maxEccentricity = nil
            return q
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
            guard queryOptions.type != nil else {
                throw ValidationError("--type is required for frameset create (e.g. --type light).")
            }
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)
            // Base query excludes maxFwhm/maxEccentricity — those are exclusion thresholds, not filters.
            let baseQuery = queryOptions.makeBaseQuery()
            let hasOtherQualityFilter = queryOptions.minStars != nil || queryOptions.maxBackgroundNoise != nil
            let hasExclusionThreshold = queryOptions.maxFwhm != nil || queryOptions.maxEccentricity != nil

            // Always inspect first so warnings are printed before any error is thrown.
            let preInspection = try await archive.inspectFrameSet(
                query: baseQuery,
                maxFWHM: queryOptions.maxFwhm,
                maxEccentricity: queryOptions.maxEccentricity
            )

            if dryRun {
                if !json {
                    try await printRejectedWarnings(archive: archive, inspection: preInspection, query: baseQuery)
                    if hasOtherQualityFilter {
                        try await printMissingQualityWarnings(archive: archive, inspection: preInspection)
                    }
                    if hasExclusionThreshold && !preInspection.excludedFrames.isEmpty {
                        printExcludedWarnings(preInspection.excludedFrames)
                    }
                }
                if json {
                    printInspectionJSON(preInspection)
                } else {
                    print(preInspection.formatted(isDryRun: true))
                }
                return
            }

            // Print warnings before attempting creation so they appear even when creation fails.
            if !json {
                try await printRejectedWarnings(archive: archive, inspection: preInspection, query: baseQuery)
                if hasOtherQualityFilter {
                    try await printMissingQualityWarnings(archive: archive, inspection: preInspection)
                }
                if hasExclusionThreshold && !preInspection.excludedFrames.isEmpty {
                    printExcludedWarnings(preInspection.excludedFrames)
                }
                // Flush the C stdio buffer so warnings appear before any error written to stderr.
                fflush(Darwin.stdout)
            }

            let setName = name ?? autoName(queryOptions)
            let (frameSet, inspection) = try await archive.createFrameSet(
                name: setName,
                query: baseQuery,
                force: force,
                maxFWHM: queryOptions.maxFwhm,
                maxEccentricity: queryOptions.maxEccentricity
            )

            if json {
                printJSON(frameSet, inspection: inspection)
            } else {
                print("Created frame set '\(frameSet.name)'  [\(frameSet.id.uuidString)]")
                print("")
                print(inspection.formatted(isDryRun: false))
            }
        }

        private func printExcludedWarnings(_ excluded: [ArchivedFrame]) {
            let n    = excluded.count
            let noun = n == 1 ? "frame" : "frames"
            let verb = n == 1 ? "was"   : "were"
            print(orangeText("⚠  \(n) \(noun) \(verb) included but marked as excluded (quality threshold exceeded):"))
            for f in excluded.prefix(5) {
                let filename = (f.filePath as NSString).lastPathComponent
                var metrics: [String] = []
                if let v = f.medianFWHM         { metrics.append(String(format: "FWHM %.2fpx", v)) }
                if let v = f.medianEccentricity  { metrics.append(String(format: "ecc %.3f", v)) }
                print(orangeText("   \(filename)  (\(metrics.joined(separator: ", ")))"))
            }
            if excluded.count > 5 { print(orangeText("   …and \(excluded.count - 5) more")) }
            print(orangeText("   Use 'ap-archive frameset include <set-id> <frame-id>' to re-enable a frame."))
            print("")
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

        /// Queries for all frames that match the base criteria (ignoring hard quality filters)
        /// and prints an orange warning for any that were excluded solely because quality data is absent.
        /// Note: maxFwhm/maxEccentricity are exclusion thresholds, not hard filters — this method
        /// only handles minStars and maxBackgroundNoise which still exclude frames entirely.
        private func printMissingQualityWarnings(
            archive: Archive,
            inspection: FrameSetInspection
        ) async throws {
            // Re-run the query without quality filters to find every candidate frame.
            var noQualityQuery = queryOptions.makeBaseQuery()
            noQualityQuery.minStarCount       = nil
            noQualityQuery.maxBackgroundNoise = nil
            let allFrames   = try await archive.frames(matching: noQualityQuery)
            let includedIDs = Set(inspection.frames.map { $0.id })

            // A frame is "missing quality data" if it is not included in the quality-filtered
            // result AND has a nil value for at least one of the active hard-filter fields.
            let excluded = allFrames.filter { f in
                !includedIDs.contains(f.id) &&
                ((queryOptions.minStars != nil           && f.starCount       == nil) ||
                 (queryOptions.maxBackgroundNoise != nil && f.backgroundNoise == nil))
            }
            guard !excluded.isEmpty else { return }

            let n = excluded.count
            let noun = n == 1 ? "frame" : "frames"
            let verb = n == 1 ? "was"   : "were"
            print(orangeText("⚠  \(n) \(noun) matched the query but \(verb) excluded — no quality data for the active filter(s):"))
            for f in excluded.prefix(5) {
                var missing: [String] = []
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
            if let v = q.camera { parts.append(v) }
            if let v = q.filter { parts.append(v) }
            if let f = q.from, let t = q.to { parts.append("\(f)–\(t)") }
            if let v = q.maxFwhm            { parts.append(String(format: "FWHM<%.1fpx", v)) }
            if let v = q.minStars           { parts.append("stars≥\(v)") }
            if let v = q.maxBackgroundNoise { parts.append(String(format: "noise<%.4f", v)) }
            if let v = q.maxEccentricity    { parts.append(String(format: "ecc<%.3f", v)) }
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
            let members = try await archive.members(inFrameSet: uuid)

            if json {
                let iso = ISO8601DateFormatter()
                var d = frameSetDict(fs, iso: iso)
                d["members"] = members.map { m in
                    var entry = frameBriefDict(m.frame, iso: iso)
                    entry["excluded"] = m.excluded
                    if let r = m.excludedReason { entry["excluded_reason"] = r }
                    return entry
                }
                writeJSON(d)
            } else {
                printTable(fs, members: members)
            }
        }

        private func printTable(_ fs: ArchivedFrameSet, members: [FrameSetMember]) {
            let iso = ISO8601DateFormatter()
            func row(_ label: String, _ value: String) {
                print(String(format: "  %-14@ %@", (label + ":") as NSString, value as NSString))
            }

            print("Frame Set  \(fs.id.uuidString)")
            print(String(repeating: "─", count: 60))
            row("Name",   fs.name)
            row("Type",   fs.frameType)
            row("Level",  fs.processingLevel.rawValue)
            let framesSuffix = fs.excludedFrameCount > 0 ? " (\(fs.excludedFrameCount) excluded)" : ""
            row("Frames", "\(fs.frameCount)\(framesSuffix)")
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

            let hasQualityAggregates = fs.medianFWHM != nil || fs.medianStarCount != nil
            if hasQualityAggregates {
                print("")
                print("Quality (medians over active frames):")
                print(String(repeating: "─", count: 60))
                if let v = fs.medianStarCount { row("Median stars", String(format: "%.0f", v)) }
                if let px = fs.medianFWHM {
                    if let arcsec = fs.medianFWHMArcsec {
                        row("Median FWHM", String(format: "%.2f px / %.2f\"", px, arcsec))
                    } else {
                        row("Median FWHM", String(format: "%.2f px", px))
                    }
                }
                if let v = fs.medianEccentricity { row("Median ecc.", String(format: "%.3f", v)) }
                if let e = fs.medianBackgroundNoiseElectrons {
                    row("Median bg.", String(format: "%.2f e⁻", e))
                } else if let n = fs.medianBackgroundNoise {
                    row("Median bg.", String(format: "%.2f ADU", n))
                }
            }

            if !members.isEmpty {
                let frames = members.map { $0.frame }
                let hasQuality = frames.contains { $0.starCount != nil || $0.medianFWHM != nil || $0.medianEccentricity != nil }
                print("")
                print("Members (\(members.count)):")
                if hasQuality {
                    var table = TextTable(columns: [
                        .init("UUID"),
                        .init("Object"),
                        .init("Level"),
                        .init("Filter"),
                        .init("Exposure", .right),
                        .init("Stars", .right),
                        .init("FWHM", .right),
                        .init("Ecc", .right),
                        .init("Background", .right),
                        .init("Date"),
                        .init("File"),
                    ])
                    for m in members {
                        let f = m.frame
                        let obj   = f.objectName ?? "-"
                        let filt  = f.filter ?? "-"
                        let exp   = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                        let stars = f.starCount.map { "\($0)" } ?? "-"
                        let fwhm: String
                        if let px = f.medianFWHM {
                            if let arcsec = f.medianFWHMArcsec {
                                fwhm = String(format: "%.2fpx/%.2f\"", px, arcsec)
                            } else {
                                fwhm = String(format: "%.2fpx", px)
                            }
                        } else { fwhm = "-" }
                        let ecc = f.medianEccentricity.map { String(format: "%.3f", $0) } ?? "-"
                        let bg: String
                        if let e = f.backgroundNoiseElectrons {
                            bg = String(format: "%.1fe⁻", e)
                        } else if let n = f.backgroundNoise {
                            bg = String(format: "%.1fADU", n)
                        } else { bg = "-" }
                        let date = f.timestamp.map { String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "-"
                        table.addRow([f.id.uuidString, obj, f.processingLevel.rawValue,
                                      filt, exp, stars, fwhm, ecc, bg, date, f.filePath])
                    }
                    let lines = table.renderLines(indent: "  ")
                    for (i, line) in lines.enumerated() {
                        if i < 2 { print(line); continue }
                        let m = members[i - 2]
                        print(m.excluded ? orangeText(line) : line)
                    }
                } else {
                    var table = TextTable(columns: [
                        .init("UUID"),
                        .init("Object"),
                        .init("Level"),
                        .init("Filter"),
                        .init("Exposure", .right),
                        .init("Date"),
                        .init("File"),
                    ])
                    for m in members {
                        let f = m.frame
                        let obj  = f.objectName ?? "-"
                        let filt = f.filter ?? "-"
                        let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                        let date = f.timestamp.map { String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "-"
                        table.addRow([f.id.uuidString, obj, f.processingLevel.rawValue, filt, exp, date, f.filePath])
                    }
                    let lines = table.renderLines(indent: "  ")
                    for (i, line) in lines.enumerated() {
                        if i < 2 { print(line); continue }
                        let m = members[i - 2]
                        print(m.excluded ? orangeText(line) : line)
                    }
                }
            }
        }
    }

    // MARK: - Add / Remove

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add frames to an existing frame set. Frames must match the set's type, "
                + "processing level, filter, and the criteria the set was created with."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID.")
        var frameSetID: String

        @Argument(help: "One or more frame UUIDs to add.")
        var frameIds: [String]

        @Flag(name: .long, help: "Skip the filter and creation-criteria checks (frame type and processing level must still match).")
        var force: Bool = false

        @Flag(name: .long, help: "Output the updated frame set as JSON.")
        var json: Bool = false

        func run() async throws {
            let (setUUID, frameUUIDs) = try parseUUIDs(set: frameSetID, frames: frameIds)
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)

            let result = try await archive.addFrames(
                toFrameSet: setUUID, frameIDs: frameUUIDs, force: force
            )

            if json {
                let iso = ISO8601DateFormatter()
                var d = frameSetDict(result.frameSet, iso: iso)
                d["added"]           = result.addedIDs.map { $0.uuidString }
                d["already_members"] = result.alreadyMemberIDs.map { $0.uuidString }
                d["excluded"]        = result.excludedReasons.map { ["id": $0.key.uuidString, "reason": $0.value] }
                writeJSON(d)
                return
            }

            let n = result.addedIDs.count
            print("Added \(n) frame\(n == 1 ? "" : "s") to frame set '\(result.frameSet.name)'.")
            if !result.alreadyMemberIDs.isEmpty {
                let m = result.alreadyMemberIDs.count
                print(orangeText("⚠  \(m) frame\(m == 1 ? " was" : "s were") already in the set and skipped:"))
                for id in result.alreadyMemberIDs.prefix(5) { print(orangeText("   \(id.uuidString)")) }
                if m > 5 { print(orangeText("   …and \(m - 5) more")) }
            }
            if !result.excludedReasons.isEmpty {
                let m = result.excludedReasons.count
                print(orangeText("⚠  \(m) frame\(m == 1 ? " was" : "s were") added but marked as excluded (quality threshold exceeded):"))
                for (id, reason) in result.excludedReasons.sorted(by: { $0.key.uuidString < $1.key.uuidString }).prefix(5) {
                    print(orangeText("   \(id.uuidString)  (\(reason))"))
                }
                if m > 5 { print(orangeText("   …and \(m - 5) more")) }
                print(orangeText("   Use 'ap-archive frameset include <set-id> <frame-id>' to re-enable a frame."))
            }
            let suffix = result.frameSet.excludedFrameCount > 0
                ? " (\(result.frameSet.excludedFrameCount) excluded)" : ""
            print("The set now contains \(result.frameSet.frameCount) frame\(result.frameSet.frameCount == 1 ? "" : "s")\(suffix).")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove frames from a frame set. The frames themselves stay in the archive."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID.")
        var frameSetID: String

        @Argument(help: "One or more frame UUIDs to remove.")
        var frameIds: [String]

        @Flag(name: .long, help: "Output the updated frame set as JSON.")
        var json: Bool = false

        func run() async throws {
            let (setUUID, frameUUIDs) = try parseUUIDs(set: frameSetID, frames: frameIds)
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)

            let result = try await archive.removeFrames(fromFrameSet: setUUID, frameIDs: frameUUIDs)

            if json {
                let iso = ISO8601DateFormatter()
                var d = frameSetDict(result.frameSet, iso: iso)
                d["removed"]     = result.removedIDs.map { $0.uuidString }
                d["not_members"] = result.notMemberIDs.map { $0.uuidString }
                writeJSON(d)
                return
            }

            let n = result.removedIDs.count
            print("Removed \(n) frame\(n == 1 ? "" : "s") from frame set '\(result.frameSet.name)'.")
            if !result.notMemberIDs.isEmpty {
                let m = result.notMemberIDs.count
                print(orangeText("⚠  \(m) frame\(m == 1 ? " was" : "s were") not in the set and skipped:"))
                for id in result.notMemberIDs.prefix(5) { print(orangeText("   \(id.uuidString)")) }
                if m > 5 { print(orangeText("   …and \(m - 5) more")) }
            }
            let suffix = result.frameSet.excludedFrameCount > 0
                ? " (\(result.frameSet.excludedFrameCount) excluded)" : ""
            print("The set now contains \(result.frameSet.frameCount) frame\(result.frameSet.frameCount == 1 ? "" : "s")\(suffix).")
        }
    }

    // MARK: - Exclude / Include

    struct Exclude: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a frame as excluded within a specific frame set. Excluded frames are skipped during processing but remain in the set."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID.")
        var frameSetID: String

        @Argument(help: "Frame UUID to exclude.")
        var frameID: String

        @Option(name: .long, help: "Optional reason for exclusion.")
        var reason: String?

        func run() async throws {
            guard let setUUID = UUID(uuidString: frameSetID) else {
                printError("Invalid frame set UUID: \(frameSetID)")
                throw ExitCode.failure
            }
            guard let frmUUID = UUID(uuidString: frameID) else {
                printError("Invalid frame UUID: \(frameID)")
                throw ExitCode.failure
            }
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)
            try await archive.setMemberExcluded(
                frameSetID: setUUID, frameID: frmUUID, excluded: true, reason: reason
            )
            let reasonSuffix = reason.map { ": \($0)" } ?? ""
            print("Frame \(frameID) marked as excluded in frame set \(frameSetID)\(reasonSuffix).")
        }
    }

    struct Include: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear the excluded flag for a frame within a specific frame set, re-enabling it for processing."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID.")
        var frameSetID: String

        @Argument(help: "Frame UUID to re-include.")
        var frameID: String

        func run() async throws {
            guard let setUUID = UUID(uuidString: frameSetID) else {
                printError("Invalid frame set UUID: \(frameSetID)")
                throw ExitCode.failure
            }
            guard let frmUUID = UUID(uuidString: frameID) else {
                printError("Invalid frame UUID: \(frameID)")
                throw ExitCode.failure
            }
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)
            try await archive.setMemberExcluded(
                frameSetID: setUUID, frameID: frmUUID, excluded: false
            )
            print("Frame \(frameID) re-included in frame set \(frameSetID).")
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

// MARK: - Shared argument parsing (file-private, used by Add/Remove)

private func parseUUIDs(set: String, frames: [String]) throws -> (UUID, [UUID]) {
    guard let setUUID = UUID(uuidString: set) else {
        throw ValidationError("Invalid frame set UUID: \(set)")
    }
    var frameUUIDs: [UUID] = []
    for s in frames {
        guard let uuid = UUID(uuidString: s) else {
            throw ValidationError("Invalid frame UUID: \(s)")
        }
        frameUUIDs.append(uuid)
    }
    return (setUUID, frameUUIDs)
}

// MARK: - Shared JSON helpers (file-private, used by all subcommands)

private func frameSetDict(_ fs: ArchivedFrameSet, iso: ISO8601DateFormatter) -> [String: Any] {
    var d: [String: Any] = [
        "id": fs.id.uuidString,
        "name": fs.name,
        "frame_type": fs.frameType,
        "processing_level": fs.processingLevel.rawValue,
        "frame_count": fs.frameCount,
        "excluded_frame_count": fs.excludedFrameCount,
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
    if let v = fs.medianStarCount               { d["median_star_count"]                = v }
    if let v = fs.medianFWHM                    { d["median_fwhm"]                      = v }
    if let v = fs.medianFWHMArcsec              { d["median_fwhm_arcsec"]               = v }
    if let v = fs.medianEccentricity            { d["median_eccentricity"]              = v }
    if let v = fs.medianBackgroundNoise         { d["median_background_noise"]          = v }
    if let v = fs.medianBackgroundNoiseElectrons { d["median_background_noise_electrons"] = v }
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
    if let v = f.objectName              { d["object_name"]                   = v }
    if let v = f.filter                  { d["filter"]                         = v }
    if let v = f.exposureTime            { d["exposure_time"]                  = v }
    if let v = f.timestamp               { d["timestamp"]                      = iso.string(from: v) }
    if let v = f.starCount               { d["star_count"]                     = v }
    if let v = f.medianFWHM              { d["median_fwhm"]                    = v }
    if let v = f.medianFWHMArcsec        { d["median_fwhm_arcsec"]             = v }
    if let v = f.medianEccentricity      { d["median_eccentricity"]            = v }
    if let v = f.backgroundNoise         { d["background_noise"]               = v }
    if let v = f.backgroundNoiseElectrons { d["background_noise_electrons"]    = v }
    if let v = f.saturatedStarCount      { d["saturated_star_count"]           = v }
    if let v = f.hotPixelCount           { d["hot_pixel_count"]                = v }
    return d
}

private func writeJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
       let str = String(data: data, encoding: .utf8) { print(str) }
}
