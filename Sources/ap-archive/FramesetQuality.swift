import ArgumentParser
import AstrophotoArchiveKit
import AstrophotoKit
import Foundation
import Metal

extension Frameset {
    struct Quality: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the frame quality pipeline on a frameset and display a per-frame quality summary.",
            discussion: """
            Runs the frame_quality pipeline on every frame that has no quality data yet,
            then prints a table showing star count, FWHM, eccentricity, and background
            noise for all members. Excluded members are highlighted in orange.

            To re-compute quality for frames that already have data, use --force.
            """
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Frame set UUID or name.")
        var frameset: String

        @Flag(name: .long, help: "Re-run quality even for frames that already have quality data.")
        var force: Bool = false

        @Option(name: .long, help: "Override max_fwhm_arcsec pipeline parameter (default 8.0\").")
        var maxFwhmArcsec: Double?

        @Option(name: .long, help: "Override max_eccentricity pipeline parameter (default 0.9).")
        var maxEccentricity: Double?

        @Flag(name: .long, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            let config  = try archiveOptions.makeConfiguration()
            let archive = try Archive(configuration: config)

            let fsUUID = try await resolveFrameSet(frameset, archive: archive)
            guard let fs = try await archive.frameSet(id: fsUUID) else {
                printError("Frame set '\(frameset)' not found.")
                throw ExitCode.failure
            }

            var members = try await archive.members(inFrameSet: fsUUID)
            guard !members.isEmpty else {
                if !json { print("Frame set '\(fs.name)' has no frames.") }
                return
            }

            let toCompute = members.filter { force || $0.frame.starCount == nil }
            let skippedCount = members.count - toCompute.count

            if !toCompute.isEmpty {
                if !json {
                    let noun = toCompute.count == 1 ? "frame" : "frames"
                    print("Running quality on \(toCompute.count) \(noun)…")
                }
                try await computeQuality(frames: toCompute.map { $0.frame }, archive: archive)
                // Reload members so newly computed metrics are reflected in the table.
                members = try await archive.members(inFrameSet: fsUUID)
            }

            if json {
                printJSON(fs: fs, members: members)
            } else {
                if toCompute.isEmpty {
                    print("All frames already have quality data. Use --force to re-run.\n")
                }
                printTable(fs: fs, members: members, skippedCount: skippedCount)
            }
        }

        // MARK: - Pipeline execution

        private func computeQuality(frames: [ArchivedFrame], archive: Archive) async throws {
            guard let device = AstrophotoKit.makeDefaultDevice() else {
                throw ValidationError("No Metal GPU device found. This tool requires a Mac with a GPU.")
            }
            guard let commandQueue = device.makeCommandQueue() else {
                throw ValidationError("Failed to create Metal command queue.")
            }
            guard let pipeline = PipelineRegistry.shared.get(id: "frame_quality") else {
                throw ValidationError("Pipeline 'frame_quality' not found in registry.")
            }

            var parameters: [String: Parameter] = [:]
            if let v = maxFwhmArcsec   { parameters["max_fwhm_arcsec"]  = .double(v) }
            if let v = maxEccentricity { parameters["max_eccentricity"] = .double(v) }

            for (index, af) in frames.enumerated() {
                let filename = (af.filePath as NSString).lastPathComponent
                if !json { print("  [\(index + 1)/\(frames.count)] \(filename)") }
                do {
                    let fitsFile = try FITSFile(path: af.filePath)
                    let img = try fitsFile.readFITSImage()
                    var frame = try Frame(fitsImage: img, device: device, filePath: af.filePath)
                    if let eg = af.egain { frame.injectEgainIfMissing(eg) }

                    let runner = PipelineRunner(pipeline: pipeline)
                    let outputs = try await runner.execute(
                        inputs: ["input_frame": frame],
                        parameters: parameters,
                        device: device,
                        commandQueue: commandQueue
                    )

                    let tables = outputs.compactMap { $0 as? TableData }.filter { $0.isInstantiated }
                    if let m = extractQualityMetrics(from: tables) {
                        try await archive.updateFrameQuality(
                            id: af.id,
                            starCount: m.starCount,
                            medianFWHM: m.medianFWHM,
                            backgroundNoise: m.backgroundNoise,
                            medianEccentricity: m.medianEccentricity,
                            saturatedStarCount: m.saturatedStarCount,
                            backgroundNoiseElectrons: m.backgroundNoiseElectrons
                        )
                    }
                } catch {
                    if !json { print("    Warning: \(error.localizedDescription)") }
                }
            }
        }

        private struct Metrics {
            var starCount: Int?
            var medianFWHM: Double?
            var medianEccentricity: Double?
            var backgroundNoise: Double?
            var backgroundNoiseElectrons: Double?
            var saturatedStarCount: Int?
        }

        private func extractQualityMetrics(from tables: [TableData]) -> Metrics? {
            for table in tables {
                guard let df = table.dataFrame else { continue }
                let cols = Set(df.columns.map { $0.name })
                guard cols.contains("star_count"), cols.contains("median_fwhm"),
                      let row = df.rows.first else { continue }

                var m = Metrics()
                m.starCount          = row["star_count"] as? Int
                m.medianFWHM         = (row["median_fwhm"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                m.medianEccentricity = row["median_eccentricity"] as? Double
                m.saturatedStarCount = row["saturated_star_count"] as? Int
                if cols.contains("background_level_adu"), let v = row["background_level_adu"] as? Double {
                    m.backgroundNoise = v
                } else {
                    m.backgroundNoise = row["background_level"] as? Double
                }
                if cols.contains("background_level_electrons") {
                    m.backgroundNoiseElectrons = row["background_level_electrons"] as? Double
                }
                return m
            }
            return nil
        }

        // MARK: - Output

        private func printTable(fs: ArchivedFrameSet, members: [FrameSetMember], skippedCount: Int) {
            let iso = ISO8601DateFormatter()
            let hasQuality = members.contains { $0.frame.starCount != nil || $0.frame.medianFWHM != nil }

            let excludedSuffix = fs.excludedFrameCount > 0 ? ", \(fs.excludedFrameCount) excluded" : ""
            print("Frame Set: \(fs.name)  [\(fs.id.uuidString)]")
            print("Frames: \(members.count)\(excludedSuffix)")
            if skippedCount > 0 {
                print("(Skipped \(skippedCount) frame(s) that already had quality data; use --force to re-run.)")
            }
            print("")

            if hasQuality {
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
                    table.addRow([f.id.uuidString, obj, filt, exp, stars, fwhm, ecc, bg, date])
                }
                let lines = table.renderLines()
                for (i, line) in lines.enumerated() {
                    guard i >= 2 else { print(line); continue }
                    print(members[i - 2].excluded ? orangeText(line) : line)
                }
            } else {
                var table = TextTable(columns: [
                    .init("ID"),
                    .init("Object"),
                    .init("Filter"),
                    .init("Exposure", .right),
                    .init("Date"),
                ])
                for m in members {
                    let f = m.frame
                    let obj  = f.objectName ?? "-"
                    let filt = f.filter ?? "-"
                    let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                    let date = f.timestamp.map {
                        String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ")
                    } ?? "-"
                    table.addRow([f.id.uuidString, obj, filt, exp, date])
                }
                let lines = table.renderLines()
                for (i, line) in lines.enumerated() {
                    guard i >= 2 else { print(line); continue }
                    print(members[i - 2].excluded ? orangeText(line) : line)
                }
            }

            // Summary statistics over active (non-excluded) frames.
            let active = members.filter { !$0.excluded }.map { $0.frame }
            let fwhmValues = active.compactMap { $0.medianFWHM }
            let eccValues  = active.compactMap { $0.medianEccentricity }
            guard !fwhmValues.isEmpty || !eccValues.isEmpty else { return }

            print("\nActive frames (\(active.count)):")
            if !fwhmValues.isEmpty {
                let med = medianValue(fwhmValues)
                if let scale = active.compactMap({ $0.pixelScale }).first {
                    print(String(format: "  Median FWHM:         %.2fpx / %.2f\"", med, med * scale))
                } else {
                    print(String(format: "  Median FWHM:         %.2fpx", med))
                }
            }
            if !eccValues.isEmpty {
                print(String(format: "  Median eccentricity: %.3f", medianValue(eccValues)))
            }
        }

        private func printJSON(fs: ArchivedFrameSet, members: [FrameSetMember]) {
            let iso = ISO8601DateFormatter()
            var d: [String: Any] = [
                "id":                    fs.id.uuidString,
                "name":                  fs.name,
                "frame_count":           fs.frameCount,
                "excluded_frame_count":  fs.excludedFrameCount,
            ]
            d["frames"] = members.map { m -> [String: Any] in
                let f = m.frame
                var entry: [String: Any] = [
                    "id":        f.id.uuidString,
                    "file_path": f.filePath,
                    "excluded":  m.excluded,
                ]
                if let v = f.objectName              { entry["object_name"]                = v }
                if let v = f.filter                  { entry["filter"]                      = v }
                if let v = f.exposureTime            { entry["exposure_time"]               = v }
                if let v = f.timestamp               { entry["timestamp"]                   = iso.string(from: v) }
                if let v = f.starCount               { entry["star_count"]                  = v }
                if let v = f.medianFWHM              { entry["median_fwhm"]                 = v }
                if let v = f.medianFWHMArcsec        { entry["median_fwhm_arcsec"]          = v }
                if let v = f.medianEccentricity      { entry["median_eccentricity"]         = v }
                if let v = f.backgroundNoise         { entry["background_noise"]             = v }
                if let v = f.backgroundNoiseElectrons { entry["background_noise_electrons"] = v }
                if let r = m.excludedReason          { entry["excluded_reason"]              = r }
                return entry
            }
            if let data = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) { print(str) }
        }

        // MARK: - Helpers

        private func resolveFrameSet(_ ref: String, archive: Archive) async throws -> UUID {
            if let u = UUID(uuidString: ref) {
                guard try await archive.frameSet(id: u) != nil else {
                    throw ValidationError("No frame set found with id '\(ref)'.")
                }
                return u
            }
            let allSets = try await archive.frameSets()
            guard let match = allSets.first(where: { $0.name.lowercased() == ref.lowercased() }) else {
                throw ValidationError(
                    "No frame set named '\(ref)'. " +
                    "Use 'ap-archive frameset list' to see available sets."
                )
            }
            return match.id
        }

        private func medianValue(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let n = sorted.count
            return n % 2 == 0
                ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
                : sorted[n / 2]
        }
    }
}
