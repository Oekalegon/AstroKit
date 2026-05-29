import ArgumentParser
import AstrophotoArchiveKit
import AstrophotoKit
import Foundation
import Metal
import TabularData

extension AP {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Execute a pipeline on one or more FITS files.",
            discussion: """
            Single-input pipeline:
              ap run star-detection --input image.fits

            Multi-input pipeline (name:path):
              ap run dark-calibration --input light_frame:light.fits --input dark_frame:dark.fits

            Multi-frame (FrameSet) pipeline — repeat the same name:
              ap run frame_registration_quad --input input_frames:frame1.fits --input input_frames:frame2.fits

            Archive frame input (by UUID):
              ap run star_detection --input input_frame:@frame:3F7A1234-…

            Archive FrameSet input (by UUID or name):
              ap run frame_stacking --input input_frames:@frameset:3F7A1234-…
              ap run frame_stacking --input "input_frames:@frameset:M51 Hɑ lights"

            With parameters:
              ap run star-detection --input image.fits --param threshold_value=4.0

            Save output table:
              ap run frame_registration_quad --input input_frames:f1.fits --input input_frames:f2.fits --output reg.fits
              ap run frame_registration_quad ... --output reg.csv --format csv
            """
        )

        @Argument(help: "Pipeline ID to execute.")
        var pipelineID: String

        @Option(name: .shortAndLong, help: "Input FITS file or archive reference. Use name:path.fits, name:@frame:UUID, or name:@frameset:UUID. Repeat with the same name to build a FrameSet.")
        var input: [String] = []

        @Option(name: .shortAndLong, help: "Pipeline parameter as key=value.")
        var param: [String] = []

        @Flag(name: .long, help: "Output results as JSON.")
        var json = false

        @Option(name: .long, help: "Write output table to this file path (e.g. result.fits or result.csv).")
        var output: String?

        // MARK: - Helpers

        /// Resolves a path to an ordered list of FITS file paths.
        /// If the path is a directory, returns all .fits/.fit/.fts files inside it (sorted).
        private func fitsFiles(at rawPath: String) throws -> [String] {
            let path = (rawPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                throw ValidationError("Path not found: \(rawPath)")
            }
            if isDir.boolValue {
                let extensions = Set(["fits", "fit", "fts"])
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                let fits = contents
                    .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
                    .sorted()
                    .map { (path as NSString).appendingPathComponent($0) }
                guard !fits.isEmpty else {
                    throw ValidationError("No FITS files found in directory: \(rawPath)")
                }
                return fits
            } else {
                return [path]
            }
        }

        @Option(name: .long, help: "Output format: fits (default) or csv.")
        var format: String = "fits"

        func run() async throws {
            guard let pipeline = PipelineRegistry.shared.get(id: pipelineID) else {
                throw ValidationError("Pipeline '\(pipelineID)' not found. Run 'ap list' to see available pipelines.")
            }

            let expectedInputs = Array(Set(pipeline.steps.flatMap { step in
                step.dataInputs.compactMap { di in di.from.contains(".") ? nil : di.from }
            })).sorted()

            guard !input.isEmpty else {
                throw ValidationError(
                    "No inputs provided. This pipeline expects: \(expectedInputs.joined(separator: ", "))\n" +
                    "Example: ap run \(pipelineID) --input \(expectedInputs.first ?? "image.fits")"
                )
            }

            // Parse --input args: collect multiple paths per named input.
            // A path may be a directory (expanded to FITS files), @frameset:UUID|name, or @frame:UUID.
            // Tuple carries an optional egain from the archive (injected when FITS header lacks EGAIN).
            var inputPaths: [String: [(path: String, egain: Double?)]] = [:]
            for raw in input {
                let (name, token): (String, String)
                if raw.hasPrefix("@frameset:") || raw.hasPrefix("@frame:") {
                    guard expectedInputs.count == 1 else {
                        throw ValidationError(
                            "Pipeline '\(pipelineID)' has multiple inputs. Use 'name:@frameset:ID' or 'name:@frame:ID' format.\n" +
                            "Expected inputs: \(expectedInputs.joined(separator: ", "))"
                        )
                    }
                    name = expectedInputs[0]
                    token = raw
                } else if let colonIdx = raw.firstIndex(of: ":") {
                    name = String(raw[..<colonIdx])
                    token = String(raw[raw.index(after: colonIdx)...])
                } else if expectedInputs.count == 1 {
                    name = expectedInputs[0]
                    token = raw
                } else {
                    throw ValidationError(
                        "Pipeline '\(pipelineID)' has multiple inputs. Use --input name:path.fits format.\n" +
                        "Expected inputs: \(expectedInputs.joined(separator: ", "))"
                    )
                }

                if token.hasPrefix("@frameset:") {
                    let ref = String(token.dropFirst("@frameset:".count))
                    let entries = try await archiveFrameSetPaths(ref: ref)
                    inputPaths[name, default: []].append(contentsOf: entries)
                } else if token.hasPrefix("@frame:") {
                    let ref = String(token.dropFirst("@frame:".count))
                    let entry = try await archiveFramePath(ref: ref)
                    inputPaths[name, default: []].append(entry)
                } else {
                    let paths = try fitsFiles(at: token)
                    inputPaths[name, default: []].append(contentsOf: paths.map { ($0, nil) })
                }
            }
            for name in expectedInputs where inputPaths[name] == nil {
                throw ValidationError("Missing input '\(name)'. Expected: \(expectedInputs.joined(separator: ", "))")
            }

            // Parse --param args as key=value
            var parameters: [String: Parameter] = [:]
            for raw in param {
                guard let eqIdx = raw.firstIndex(of: "=") else {
                    throw ValidationError("Invalid parameter '\(raw)'. Use: key=value")
                }
                let key = String(raw[..<eqIdx])
                let val = String(raw[raw.index(after: eqIdx)...])
                if let i = Int(val)         { parameters[key] = .int(i) }
                else if let d = Double(val) { parameters[key] = .double(d) }
                else                        { parameters[key] = .string(val) }
            }

            guard let device = AstrophotoKit.makeDefaultDevice() else {
                throw APError("No Metal GPU device found. This tool requires a Mac with a GPU.")
            }
            guard let commandQueue = device.makeCommandQueue() else {
                throw APError("Failed to create Metal command queue.")
            }

            // Load FITS inputs — single path → Frame, multiple paths → FrameSet.
            // Paths were already validated and expanded by fitsFiles(at:).
            // Always create Frame (not raw FITSImage) so file paths and FITS metadata are preserved.
            // When a frame came from an @frame:/@frameset: archive reference, inject egain from
            // the archive DB if the FITS header did not carry it (e.g. PlayerOne cameras at fixed gain).
            var pipelineInputs: [String: Any] = [:]
            for (name, entries) in inputPaths {
                if entries.count == 1 {
                    let (path, archiveEgain) = entries[0]
                    let fitsFile = try FITSFile(path: path)
                    let img = try fitsFile.readFITSImage()
                    var frame = try Frame(fitsImage: img, device: device, filePath: path)
                    if let eg = archiveEgain { frame.injectEgainIfMissing(eg) }
                    pipelineInputs[name] = frame
                } else {
                    var frames: [Frame] = []
                    for (path, archiveEgain) in entries {
                        let fitsFile = try FITSFile(path: path)
                        let img = try fitsFile.readFITSImage()
                        var frame = try Frame(fitsImage: img, device: device, filePath: path)
                        if let eg = archiveEgain { frame.injectEgainIfMissing(eg) }
                        frames.append(frame)
                    }
                    pipelineInputs[name] = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])
                }
            }

            // Build a map of pipeline-level input names → expected DataType.
            // Pipeline inputs are step dataInputs whose `from` field has no dot.
            let pipelineInputTypeMap: [String: DataType] = Dictionary(
                pipeline.steps
                    .flatMap { $0.dataInputs }
                    .filter { !$0.from.contains(".") }
                    .map { ($0.from, $0.type) },
                uniquingKeysWith: { first, _ in first }
            )

            // Detect if a FrameSet was supplied for an input that expects a single Frame.
            // This happens when @frameset:UUID is passed to a pipeline like frame_quality that
            // takes one frame at a time.  The PipelineRunner's DataStack type-checks inputs
            // strictly, so a FrameSet would silently produce zero outputs.
            // Fix: run the pipeline once per frame in the FrameSet.
            var frameLoopName: String? = nil
            var frameLoopItems: [Frame] = []
            for (name, value) in pipelineInputs {
                if let fs = value as? FrameSet, pipelineInputTypeMap[name] == .frame {
                    frameLoopName = name
                    frameLoopItems = fs.frames
                    break
                }
            }

            if let loopName = frameLoopName, !frameLoopItems.isEmpty {
                if output != nil {
                    throw ValidationError(
                        "--output is not supported when running a pipeline on a frameset. " +
                        "Run on individual frames to save results."
                    )
                }
                if !json {
                    print("Running '\(pipelineID)' on \(frameLoopItems.count) frame(s)…")
                }
                let start = Date()
                var totalTables = 0, totalResultFrames = 0
                var jsonRows: [[String: Any]] = []

                for (idx, frame) in frameLoopItems.enumerated() {
                    var perFrameInputs = pipelineInputs
                    perFrameInputs[loopName] = frame

                    let runner = PipelineRunner(pipeline: pipeline)
                    let frameOutputs = try await runner.execute(
                        inputs: perFrameInputs,
                        parameters: parameters,
                        device: device,
                        commandQueue: commandQueue
                    )

                    let frameTables  = frameOutputs.compactMap { $0 as? TableData }.filter { $0.isInstantiated }
                    let allFrames    = frameOutputs.compactMap { $0 as? Frame     }.filter { $0.isInstantiated }
                    // Only archive frames from the last pipeline step; discard intermediates.
                    let frameResults = terminalFrames(from: allFrames, pipeline: pipeline)
                    totalTables      += frameTables.count
                    totalResultFrames += frameResults.count

                    if !frameResults.isEmpty {
                        await autoArchiveResults(
                            frames: frameResults,
                            pipelineID: pipelineID,
                            parameters: parameters,
                            pipelineInputs: perFrameInputs,
                            existingOutputPath: nil
                        )
                    }
                    if !frameTables.isEmpty {
                        await backUpdateQuality(tables: frameTables, pipelineInputs: perFrameInputs, parameters: parameters)
                    }

                    if json {
                        var row: [String: Any] = ["frame_index": idx]
                        for (i, table) in frameTables.enumerated() {
                            if let d = tableToDict(table) { row["table_\(i)"] = d }
                        }
                        jsonRows.append(row)
                    }
                }

                let elapsed = Date().timeIntervalSince(start)
                if json {
                    let result: [String: Any] = [
                        "pipeline": pipelineID,
                        "frame_count": frameLoopItems.count,
                        "elapsed_seconds": elapsed,
                        "frames": jsonRows
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
                       let str = String(data: data, encoding: .utf8) { print(str) }
                } else {
                    print(String(
                        format: "Done in %.2fs — %d frame(s) processed, %d table(s) per frame.",
                        elapsed, frameLoopItems.count,
                        frameLoopItems.isEmpty ? 0 : totalTables / frameLoopItems.count
                    ))
                }
                return
            }

            if !json { print("Running '\(pipelineID)'…") }

            let start = Date()
            let runner = PipelineRunner(pipeline: pipeline)
            let outputs = try await runner.execute(
                inputs: pipelineInputs,
                parameters: parameters,
                device: device,
                commandQueue: commandQueue
            )
            let elapsed = Date().timeIntervalSince(start)

            let tables = outputs.compactMap { $0 as? TableData }.filter { $0.isInstantiated }
            let frames = outputs.compactMap { $0 as? Frame }.filter { $0.isInstantiated }

            // Save output if requested
            if let outputPath = output {
                // A registration table is identified by its frame_index column.
                let regTable = tables.first(where: {
                    $0.dataFrame?.columns.contains(where: { $0.name == "frame_index" }) == true
                })
                if let firstFrame = frames.first, let regDF = regTable?.dataFrame,
                   format.lowercased() != "csv" {
                    // Stacked image + registration table → combined FITS
                    guard let texture = firstFrame.texture else {
                        throw APError("Output frame has no texture data")
                    }
                    let w = texture.width, h = texture.height
                    var pixels = [Float](repeating: 0, count: w * h)
                    texture.getBytes(&pixels,
                                     bytesPerRow: w * MemoryLayout<Float>.size,
                                     from: MTLRegionMake2D(0, 0, w, h),
                                     mipmapLevel: 0)
                    let stackMethod     = parameters["method"]?.stringValue          ?? "average"
                    let stackNorm       = parameters["normalisation"]?.stringValue    ?? "none"
                    let stackRej        = parameters["pixel_rejection"]?.stringValue  ?? "sigma_clip"
                    let stackRejLow     = parameters["rejection_low"]?.doubleValue    ?? 3.0
                    let stackRejHigh    = parameters["rejection_high"]?.doubleValue   ?? 3.0
                    try FITSTableWriter.writeStackedOutput(
                        pixelData: pixels, width: w, height: h,
                        registrationTable: regDF,
                        method: stackMethod,
                        normalisation: stackNorm,
                        rejection: stackRej,
                        rejectionLow: stackRejLow,
                        rejectionHigh: stackRejHigh,
                        to: outputPath
                    )
                    if !json {
                        print("Saved stacked FITS to \(outputPath)")
                        printStackSummary(pixels: pixels, registrationTable: regDF,
                                          inputFrameSet: pipelineInputs["input_frames"] as? FrameSet)
                    }
                } else if let firstFrame = frames.first {
                    // Frame output without registration table (e.g. star_detection_diagnostic)
                    guard let texture = firstFrame.texture else {
                        throw APError("Output frame has no texture data")
                    }
                    let w = texture.width, h = texture.height
                    let bytesPerPixel = texture.pixelFormat == .rgba32Float ? 4 : 1
                    let bytesPerRow   = w * bytesPerPixel * MemoryLayout<Float>.size
                    var rawPixels = [Float](repeating: 0, count: w * h * bytesPerPixel)
                    texture.getBytes(&rawPixels, bytesPerRow: bytesPerRow,
                                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                    let pixels: [Float] = bytesPerPixel > 1
                        ? stride(from: 0, to: rawPixels.count, by: bytesPerPixel).map { rawPixels[$0] }
                        : rawPixels
                    try FITSTableWriter.writeResultFrame(
                        pixelData: pixels, width: w, height: h,
                        pipelineID: pipelineID,
                        imageType: "Light Frame",
                        filterName: firstFrame.filterName,
                        stacked: false,
                        to: outputPath
                    )
                    if !json { print("Saved frame to \(outputPath)") }
                } else if let firstTable = tables.first, let df = firstTable.dataFrame {
                    // Table-only output (e.g. frame_registration_quad)
                    let outputFormat: FITSTableWriter.OutputFormat = (format.lowercased() == "csv") ? .csv : .fits
                    try FITSTableWriter.writeRegistrationTable(df, to: outputPath, format: outputFormat)
                    if !json { print("Saved table to \(outputPath) (\(format.lowercased()))") }
                }
            }

            // Auto-archive result frames from the LAST pipeline step only.
            // Intermediate frames (blurred_frame, background_frame, etc.) are produced
            // by earlier steps and must not be stored as archive entries.
            let resultFrames = terminalFrames(from: frames, pipeline: pipeline)
            if !resultFrames.isEmpty {
                await autoArchiveResults(
                    frames: resultFrames,
                    pipelineID: pipelineID,
                    parameters: parameters,
                    pipelineInputs: pipelineInputs,
                    existingOutputPath: (output?.hasSuffix(".fits") == true || output?.hasSuffix(".fit") == true) ? output : nil
                )
            }

            // Back-update quality metrics on the input archive frame(s) when an analysis
            // pipeline produces star/FWHM/background data.
            if !tables.isEmpty {
                await backUpdateQuality(tables: tables, pipelineInputs: pipelineInputs, parameters: parameters)
            }

            if json {
                let result: [String: Any] = [
                    "pipeline": pipelineID,
                    "elapsed_seconds": elapsed,
                    "frame_count": frames.count,
                    "tables": tables.compactMap { tableToDict($0) },
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                print("Done in \(String(format: "%.2f", elapsed))s — \(frames.count) frame(s), \(tables.count) table(s).")
                for (i, table) in tables.enumerated() {
                    printTable(table, index: i + 1)
                }
            }
        }

        /// Extracts quality metrics from pipeline output tables and persists them on the
        /// matching input archive frame(s). Silently skips if no archive is configured or
        /// if the pipeline did not produce recognisable quality tables.
        ///
        /// Handles two cases:
        /// - **Per-frame** (registration table from frame_registration_quad / frame_stacking): each row
        ///   is matched to an archive frame by its `file_path` column.
        /// - **Single-frame** (summary tables from star_detection / optical_quality / autofocus):
        ///   the aggregate result is applied to each archive frame found among `pipelineInputs`.
        /// Returns only the frames produced by the last step of the pipeline.
        /// Intermediate processing frames (blurred, background-subtracted, eroded, etc.)
        /// are produced by earlier steps and should not be archived as result frames.
        private func terminalFrames(from frames: [Frame], pipeline: Pipeline) -> [Frame] {
            guard let lastStepID = pipeline.steps.last?.id else { return frames }
            return frames.filter { frame in
                guard let outputLink = frame.outputLink,
                      case .output(_, _, _, let stepLinkID) = outputLink else { return false }
                // stepLinkID is "stepId.outputName" or "stepId[n].outputName" for split steps.
                let stepPart   = String(stepLinkID.split(separator: ".").first ?? Substring(stepLinkID))
                let baseStepID = String(stepPart.split(separator: "[").first ?? Substring(stepPart))
                return baseStepID == lastStepID
            }
        }

        private func backUpdateQuality(
            tables: [TableData],
            pipelineInputs: [String: Any],
            parameters: [String: Parameter] = [:]
        ) async {
            guard let config = try? ArchiveConfiguration.fromEnvironment(),
                  let archive = try? Archive(configuration: config) else { return }

            let maxFWHM         = parameters["max_fwhm"]?.doubleValue
            let maxEccentricity = parameters["max_eccentricity"]?.doubleValue

            // 1. Per-frame path: registration table from frame_registration_quad / frame_stacking.
            let perFrame = extractPerFrameQuality(from: tables)
            if !perFrame.isEmpty {
                for entry in perFrame {
                    guard let af = try? await archive.frame(filePath: entry.filePath) else { continue }
                    do {
                        try await archive.updateFrameQuality(
                            id: af.id,
                            starCount: entry.starCount,
                            medianFWHM: entry.medianFWHM,
                            backgroundNoise: nil,
                            medianEccentricity: entry.medianEccentricity
                        )
                        if !json {
                            var parts: [String] = []
                            if let v = entry.starCount          { parts.append("stars: \(v)") }
                            if let v = entry.medianFWHM         { parts.append(String(format: "FWHM: %.2fpx", v)) }
                            if let v = entry.medianEccentricity { parts.append(String(format: "ecc: %.3f", v)) }
                            print("Quality → \(af.id): \(parts.joined(separator: ", "))")
                        }
                        await applyFrameSetExclusion(
                            archive: archive,
                            frameID: af.id,
                            fwhm: entry.medianFWHM,
                            eccentricity: entry.medianEccentricity,
                            maxFWHM: maxFWHM,
                            maxEccentricity: maxEccentricity
                        )
                    } catch {
                        if !json { print("Warning: quality update failed: \(error.localizedDescription)") }
                    }
                }
                return
            }

            // 2. Single-frame path: summary tables from analysis pipelines.
            let metrics = extractGlobalQuality(from: tables)
            guard metrics.starCount != nil || metrics.medianFWHM != nil || metrics.backgroundNoise != nil
                    || metrics.medianEccentricity != nil || metrics.saturatedStarCount != nil
                    || metrics.hotPixelCount != nil else {
                return
            }

            var inputPaths: [String] = []
            for value in pipelineInputs.values {
                if let frameSet = value as? FrameSet {
                    inputPaths += frameSet.frames.compactMap { $0.filePath }
                } else if let frame = value as? Frame, let path = frame.filePath {
                    inputPaths.append(path)
                }
            }

            for path in inputPaths {
                guard let af = try? await archive.frame(filePath: path) else { continue }
                do {
                    try await archive.updateFrameQuality(
                        id: af.id,
                        starCount: metrics.starCount,
                        medianFWHM: metrics.medianFWHM,
                        backgroundNoise: metrics.backgroundNoise,
                        medianEccentricity: metrics.medianEccentricity,
                        saturatedStarCount: metrics.saturatedStarCount,
                        hotPixelCount: metrics.hotPixelCount,
                        backgroundNoiseElectrons: metrics.backgroundNoiseElectrons
                    )
                    if !json {
                        var parts: [String] = []
                        if let v = metrics.starCount          { parts.append("stars: \(v)") }
                        if let v = metrics.saturatedStarCount { parts.append("sat: \(v)") }
                        if let v = metrics.medianFWHM         { parts.append(String(format: "FWHM: %.2fpx", v)) }
                        if let v = metrics.backgroundNoiseElectrons {
                            parts.append(String(format: "bg: %.2f e⁻", v))
                        } else if let v = metrics.backgroundNoise {
                            if metrics.backgroundNoiseIsADU {
                                parts.append(String(format: "bg: %.2f ADU", v))
                            } else {
                                parts.append(String(format: "bg: %.4f", v))
                            }
                        }
                        if let v = metrics.medianEccentricity { parts.append(String(format: "ecc: %.3f", v)) }
                        if let v = metrics.hotPixelCount      { parts.append("hot_px: \(v)") }
                        print("Quality → \(af.id): \(parts.joined(separator: ", "))")
                    }
                    await applyFrameSetExclusion(
                        archive: archive,
                        frameID: af.id,
                        fwhm: metrics.medianFWHM,
                        eccentricity: metrics.medianEccentricity,
                        maxFWHM: maxFWHM,
                        maxEccentricity: maxEccentricity
                    )
                } catch {
                    if !json { print("Warning: quality update failed for \(path): \(error.localizedDescription)") }
                }
            }
        }

        /// After updating quality metrics on an archived frame, marks the frame as excluded
        /// (or re-includes it) in any frame sets it belongs to, based on FWHM/eccentricity thresholds.
        private func applyFrameSetExclusion(
            archive: Archive,
            frameID: UUID,
            fwhm: Double?,
            eccentricity: Double?,
            maxFWHM: Double?,
            maxEccentricity: Double?
        ) async {
            guard maxFWHM != nil || maxEccentricity != nil else { return }
            let exceedsFWHM = maxFWHM.map { (fwhm ?? .infinity) > $0 } ?? false
            let exceedsEcc  = maxEccentricity.map { (eccentricity ?? .infinity) > $0 } ?? false
            let shouldExclude = exceedsFWHM || exceedsEcc

            guard let fsIDs = try? await archive.frameSetIDs(forFrame: frameID), !fsIDs.isEmpty else { return }

            var reason: String? = nil
            if exceedsFWHM, let f = fwhm, let max = maxFWHM {
                reason = String(format: "FWHM %.2fpx exceeds threshold %.2fpx", f, max)
            } else if exceedsEcc, let e = eccentricity, let max = maxEccentricity {
                reason = String(format: "eccentricity %.3f exceeds threshold %.3f", e, max)
            }

            for fsID in fsIDs {
                do {
                    try await archive.setMemberExcluded(
                        frameSetID: fsID, frameID: frameID,
                        excluded: shouldExclude, reason: shouldExclude ? reason : nil
                    )
                    if !json && shouldExclude {
                        print("  Excluded from frameset \(fsID): \(reason ?? "quality threshold")")
                    }
                } catch {
                    if !json { print("Warning: frameset exclusion update failed: \(error.localizedDescription)") }
                }
            }
        }

        /// Extracts per-frame quality metrics from a registration table (frame_registration_quad /
        /// frame_stacking). Identified by `file_path`, `median_fwhm`, and `star_count` columns.
        /// `sky_noise` is not mapped to `backgroundNoise` because it is in ADU, not normalised 0–1.
        private func extractPerFrameQuality(
            from tables: [TableData]
        ) -> [(filePath: String, starCount: Int?, medianFWHM: Double?, medianEccentricity: Double?)] {
            for table in tables {
                guard let df = table.dataFrame else { continue }
                let colNames = Set(df.columns.map { $0.name })
                guard colNames.contains("file_path"),
                      colNames.contains("median_fwhm"),
                      colNames.contains("star_count") else { continue }

                var results: [(filePath: String, starCount: Int?, medianFWHM: Double?, medianEccentricity: Double?)] = []
                for row in df.rows {
                    guard let path = row["file_path"] as? String, !path.isEmpty else { continue }
                    let starCount: Int? = (row["star_count"] as? Int32).map { Int($0) }
                        ?? (row["star_count"] as? Int)
                    let medianFWHM         = row["median_fwhm"] as? Double
                    let medianEccentricity = row["mean_eccentricity"] as? Double
                    results.append((filePath: path, starCount: starCount, medianFWHM: medianFWHM, medianEccentricity: medianEccentricity))
                }
                return results
            }
            return []
        }

        /// Extracts aggregate quality metrics from single-frame analysis pipeline output tables.
        private func extractGlobalQuality(
            from tables: [TableData]
        ) -> (starCount: Int?, medianFWHM: Double?, backgroundNoise: Double?, backgroundNoiseIsADU: Bool, backgroundNoiseElectrons: Double?, medianEccentricity: Double?, saturatedStarCount: Int?, hotPixelCount: Int?) {
            var starCount: Int? = nil
            var medianFWHM: Double? = nil
            var backgroundNoise: Double? = nil
            var backgroundNoiseIsADU = false
            var backgroundNoiseElectrons: Double? = nil
            var medianEccentricity: Double? = nil
            var saturatedStarCount: Int? = nil
            var hotPixelCount: Int? = nil

            for table in tables {
                guard let df = table.dataFrame else { continue }
                let colNames = Set(df.columns.map { $0.name })

                // frame_quality table — compact summary from FrameQualityProcessor.
                if colNames.contains("star_count") && colNames.contains("saturated_star_count"),
                   let row = df.rows.first {
                    if let v = row["star_count"]           as? Int  { starCount = v }
                    if let v = row["saturated_star_count"] as? Int  { saturatedStarCount = v }
                    if let v = row["median_fwhm"]          as? Double, v > 0 { medianFWHM = v }
                    if let v = row["median_eccentricity"]  as? Double { medianEccentricity = v }
                    // Prefer ADU background over normalised; guard column existence first
                    // because TabularData Row.subscript traps on missing columns.
                    if colNames.contains("background_level_adu"),
                       let v = row["background_level_adu"] as? Double {
                        backgroundNoise = v; backgroundNoiseIsADU = true
                    } else if let v = row["background_level"] as? Double {
                        backgroundNoise = v
                    }
                    if colNames.contains("background_level_electrons"),
                       let v = row["background_level_electrons"] as? Double {
                        backgroundNoiseElectrons = v
                    }
                }

                // calibration_quality table — from CalibrationQualityProcessor.
                if colNames.contains("noise_sigma") && colNames.contains("hot_pixel_count"),
                   let row = df.rows.first {
                    if let v = row["hot_pixel_count"] as? Int { hotPixelCount = v }
                    if colNames.contains("noise_sigma_adu"),
                       let v = row["noise_sigma_adu"] as? Double {
                        backgroundNoise = v; backgroundNoiseIsADU = true
                    } else if let v = row["noise_sigma"] as? Double {
                        backgroundNoise = v
                    }
                    if colNames.contains("noise_sigma_electrons"),
                       let v = row["noise_sigma_electrons"] as? Double {
                        backgroundNoiseElectrons = v
                    }
                }

                // Legacy: per-star table (star_detection / optical_quality).
                if colNames.contains("centroid_x") && colNames.contains("centroid_y") {
                    if starCount == nil { starCount = df.rows.count }
                    if medianEccentricity == nil {
                        let eccs = df.rows.compactMap { $0["eccentricity"] as? Double }.filter { !$0.isNaN }
                        if !eccs.isEmpty { medianEccentricity = eccs.reduce(0, +) / Double(eccs.count) }
                    }
                }
                // Legacy: FWHM summary table (star_detection).
                if colNames.contains("sigma_clipped_mean_fwhm_major"),
                   colNames.contains("sigma_clipped_mean_fwhm_minor"),
                   let row = df.rows.first,
                   let major = row["sigma_clipped_mean_fwhm_major"] as? Double,
                   let minor = row["sigma_clipped_mean_fwhm_minor"] as? Double,
                   major > 0, medianFWHM == nil {
                    medianFWHM = (major + minor) / 2.0
                }
                // Legacy: background level table (background_estimation).
                // Prefer ADU column when present (BackgroundEstimationProcessor emits
                // background_level_adu whenever the frame has FITS scale info).
                if colNames.contains("background_level"),
                   !colNames.contains("star_count"),   // avoid double-counting frame_quality table
                   let row = df.rows.first,
                   backgroundNoise == nil {
                    if colNames.contains("background_level_adu"),
                       let v = row["background_level_adu"] as? Double {
                        backgroundNoise = v; backgroundNoiseIsADU = true
                    } else if let v = row["background_level"] as? Double {
                        backgroundNoise = v
                    }
                }
                // Legacy: optical_quality summary eccentricity.
                if colNames.contains("global_mean_eccentricity"),
                   let row = df.rows.first,
                   let ecc = row["global_mean_eccentricity"] as? Double,
                   medianEccentricity == nil {
                    medianEccentricity = ecc
                }
            }
            return (starCount, medianFWHM, backgroundNoise, backgroundNoiseIsADU, backgroundNoiseElectrons, medianEccentricity, saturatedStarCount, hotPixelCount)
        }

        private func autoArchiveResults(
            frames: [Frame],
            pipelineID: String,
            parameters: [String: Parameter],
            pipelineInputs: [String: Any],
            existingOutputPath: String?
        ) async {
            guard let config = try? ArchiveConfiguration.fromEnvironment() else { return }
            guard let archive = try? Archive(configuration: config) else { return }

            do {
                // Collect provenance and input frame metadata in one pass.
                var runInputs: [ProcessingRunInputRef] = []
                var objectNamesSet: Set<String> = []
                var filterNamesSet: Set<String> = []
                var camerasSet: Set<String> = []
                var pixelScalesSet: Set<Double> = []
                var focalLengthsSet: Set<Double> = []
                var totalExposure = 0.0
                var inputCount = 0
                var gainsSet: Set<Double> = []
                var offsetsSet: Set<Double> = []
                var temperatures: [Double] = []
                var timestamps: [Date] = []
                var refRA: Double? = nil
                var refDec: Double? = nil

                for (name, value) in pipelineInputs.sorted(by: { $0.key < $1.key }) {
                    let pathsAndFrames: [(String, Frame?)]
                    if let frameSet = value as? FrameSet {
                        pathsAndFrames = frameSet.frames.compactMap { f in f.filePath.map { ($0, f) } }
                    } else if let frame = value as? Frame {
                        pathsAndFrames = frame.filePath.map { [($0, frame as Frame?)] } ?? []
                    } else {
                        pathsAndFrames = []
                    }
                    for (pos, (path, inputFrame)) in pathsAndFrames.enumerated() {
                        let af = try? await archive.frame(filePath: path)
                        runInputs.append(ProcessingRunInputRef(
                            inputName: name, frameID: af?.id, filePath: path, position: pos
                        ))
                        if pos == 0 { refRA = af?.ra; refDec = af?.dec }
                        inputCount += 1
                        if let v = af?.objectName { objectNamesSet.insert(v) }
                        let fn = af?.filter ?? inputFrame?.filterName
                        if let fn { filterNamesSet.insert(fn) }
                        let exp = af?.exposureTime ?? inputFrame?.exposureTime
                        if let exp { totalExposure += exp }
                        if let g = af?.gain ?? inputFrame?.gain { gainsSet.insert(g) }
                        if let o = af?.offset ?? inputFrame?.offset { offsetsSet.insert(o) }
                        if let t = af?.temperature { temperatures.append(t) }
                        if let ts = af?.timestamp ?? inputFrame?.timestamp { timestamps.append(ts) }
                        if let c = af?.camera { camerasSet.insert(c) }
                        if let ps = af?.pixelScale { pixelScalesSet.insert(ps) }
                        if let fl = af?.focalLength { focalLengthsSet.insert(fl) }
                    }
                }

                let stackObjectName  = objectNamesSet.count == 1 ? objectNamesSet.first : nil
                let stackFilter      = filterNamesSet.count == 1 ? filterNamesSet.first : nil
                let stackCamera      = camerasSet.count == 1 ? camerasSet.first : nil
                let stackPixelScale  = pixelScalesSet.count == 1 ? pixelScalesSet.first : nil
                let stackFocalLength = focalLengthsSet.count == 1 ? focalLengthsSet.first : nil
                let stackExposure    = inputCount > 0 && totalExposure > 0 ? totalExposure : nil as Double?
                let stackGain        = gainsSet.count == 1 ? gainsSet.first : nil
                let stackOffset      = offsetsSet.count == 1 ? offsetsSet.first : nil
                let stackTempMean    = temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count) as Double?
                let stackTempMin     = temperatures.isEmpty ? nil : temperatures.min()
                let stackTempMax     = temperatures.isEmpty ? nil : temperatures.max()

                let iso8601 = ISO8601DateFormatter()
                iso8601.formatOptions = [.withInternetDateTime]
                let refDate = timestamps.max().flatMap { iso8601.string(from: $0) }
                let dateBeg = timestamps.min().flatMap { iso8601.string(from: $0) }
                let dateEnd = timestamps.max().flatMap { iso8601.string(from: $0) }

                let paramMap = parameters.reduce(into: [String: String]()) { $0[$1.key] = $1.value.stringValue }
                let run = try await archive.recordProcessingRun(
                    pipelineID: pipelineID, parameters: paramMap, inputs: runInputs
                )

                for frame in frames {
                    guard let texture = frame.texture else { continue }
                    let w = texture.width, h = texture.height
                    let bytesPerPixel = texture.pixelFormat == .rgba32Float ? 4 : 1
                    let bytesPerRow   = w * bytesPerPixel * MemoryLayout<Float>.size
                    var rawPixels = [Float](repeating: 0, count: w * h * bytesPerPixel)
                    texture.getBytes(&rawPixels,
                                     bytesPerRow: bytesPerRow,
                                     from: MTLRegionMake2D(0, 0, w, h),
                                     mipmapLevel: 0)
                    let pixels: [Float] = bytesPerPixel > 1
                        ? stride(from: 0, to: rawPixels.count, by: bytesPerPixel).map { rawPixels[$0] }
                        : rawPixels

                    // Reuse the user's output file if there's exactly one result frame.
                    let tempURL: URL?
                    let fileToArchive: URL
                    if let outPath = existingOutputPath, frames.count == 1 {
                        fileToArchive = URL(fileURLWithPath: outPath)
                        tempURL = nil
                    } else {
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ap_result_\(UUID().uuidString).fits")
                        try FITSTableWriter.writeResultFrame(
                            pixelData: pixels, width: w, height: h,
                            pipelineID: pipelineID,
                            imageType: "Light Frame",
                            filterName: stackFilter ?? frame.filterName,
                            stacked: pipelineID == "frame_stacking",
                            nframes: inputCount > 0 ? inputCount : nil,
                            totalExposure: stackExposure,
                            gain: stackGain,
                            offset: stackOffset,
                            temperature: stackTempMean,
                            objectName: stackObjectName,
                            camera: stackCamera,
                            ra: refRA,
                            dec: refDec,
                            pixelScale: stackPixelScale,
                            focalLength: stackFocalLength,
                            tempMin: stackTempMin,
                            tempMax: stackTempMax,
                            dateObs: refDate,
                            dateBeg: dateBeg,
                            dateEnd: dateEnd,
                            to: tmp.path
                        )
                        fileToArchive = tmp
                        tempURL = tmp
                    }

                    let (archived, isNew) = try await archive.add(fitsFile: fileToArchive, processingRunID: run.id)
                    if let tmp = tempURL { try? FileManager.default.removeItem(at: tmp) }

                    if !json {
                        if isNew {
                            print("Archived result → \(archived.id)")
                        } else {
                            print("Result already in archive: \(archived.id)")
                        }
                    }
                }
            } catch {
                if !json { print("Warning: auto-archive failed: \(error.localizedDescription)") }
            }
        }

        private func archiveFramePath(ref: String) async throws -> (path: String, egain: Double?) {
            guard let uuid = UUID(uuidString: ref) else {
                throw ValidationError("@frame: reference must be a valid UUID: '\(ref)'.")
            }
            let config = try ArchiveConfiguration.fromEnvironment()
            let archive = try Archive(configuration: config)
            guard let frame = try await archive.frame(id: uuid) else {
                throw ValidationError("No archive frame found with id '\(ref)'.")
            }
            return (frame.filePath, frame.egain)
        }

        private func archiveFrameSetPaths(ref: String) async throws -> [(path: String, egain: Double?)] {
            let config = try ArchiveConfiguration.fromEnvironment()
            let archive = try Archive(configuration: config)

            let uuid: UUID
            if let u = UUID(uuidString: ref) {
                uuid = u
                guard try await archive.frameSet(id: uuid) != nil else {
                    throw ValidationError("No archive frame set found with id '\(ref)'.")
                }
            } else {
                let allSets = try await archive.frameSets()
                guard let match = allSets.first(where: { $0.name.lowercased() == ref.lowercased() }) else {
                    throw ValidationError(
                        "No archive frame set named '\(ref)'. " +
                        "Use 'ap-archive frameset list' to see available sets."
                    )
                }
                uuid = match.id
            }

            let frames = try await archive.frames(inFrameSet: uuid)
            guard !frames.isEmpty else {
                throw ValidationError("Archive frame set '\(ref)' contains no frames.")
            }
            return frames.map { ($0.filePath, $0.egain) }
        }

        private func tableToDict(_ table: TableData) -> [String: Any]? {
            guard let df = table.dataFrame else { return nil }
            let cols = df.columns.map { $0.name }
            var rows: [[String: Any]] = []
            for row in df.rows {
                var d: [String: Any] = [:]
                for col in cols {
                    guard let v = row[col] else { continue }
                    switch v {
                    case let x as Double: d[col] = x
                    case let x as Float:  d[col] = Double(x)
                    case let x as Int:    d[col] = x
                    case let x as Int32:  d[col] = Int(x)
                    case let x as String: d[col] = x
                    default:              d[col] = "\(v)"
                    }
                }
                rows.append(d)
            }
            return ["columns": cols, "rows": rows]
        }

        private func printStackSummary(pixels: [Float], registrationTable df: DataFrame, inputFrameSet: FrameSet?) {
            let skyNoises = df.rows.compactMap { $0["sky_noise"] as? Double }.filter { !$0.isNaN && $0 > 0 }
            guard !skyNoises.isEmpty else { return }

            let n = skyNoises.count
            let meanNoise    = skyNoises.reduce(0, +) / Double(n)
            let expectedNoise = meanNoise / sqrt(Double(n))

            // NMAD on stacked pixels — same algorithm as FITSTableWriter
            let strideStep = max(1, pixels.count / 65536)
            var sample = [Double]()
            sample.reserveCapacity(65537)
            var sIdx = 0
            while sIdx < pixels.count { sample.append(Double(pixels[sIdx])); sIdx += strideStep }
            sample.sort()
            let bgNorm = sample[sample.count / 2]
            var devs = sample.map { abs($0 - bgNorm) }
            devs.sort()
            let stackedNoiseNorm = 1.4826 * devs[devs.count / 2]

            // Convert normalized noise to ADU using reference frame's pixel scale
            var stackedNoiseADU: Double? = nil
            if let refFrame = inputFrameSet?.frames.first,
               let fitsMin  = refFrame.fitsMinValue,
               let fitsMax  = refFrame.fitsMaxValue {
                stackedNoiseADU = stackedNoiseNorm * (fitsMax - fitsMin)
            }

            let sqrtN = sqrt(Double(n))
            if let sn = stackedNoiseADU {
                print(String(format: "\nStack (%d frames): per-frame avg %.2f ADU  →  measured %.2f ADU  (expected %.2f, √%d=%.2f×)",
                             n, meanNoise, sn, expectedNoise, n, sqrtN))
            } else {
                print(String(format: "\nStack (%d frames): per-frame avg %.2f ADU  →  expected %.2f ADU  (√%d=%.2f×)",
                             n, meanNoise, expectedNoise, n, sqrtN))
            }
        }

        private func printTable(_ table: TableData, index: Int) {
            guard let df = table.dataFrame else { return }
            let cols = df.columns.map { $0.name }
            guard !cols.isEmpty else { return }
            print("\nTable \(index) (\(df.rows.count) rows):")
            print("  " + cols.joined(separator: "\t"))
            for row in df.rows.prefix(30) {
                let vals = cols.map { col -> String in
                    guard let v = row[col] else { return "-" }
                    if let d = v as? Double { return String(format: "%.4f", d) }
                    if let f = v as? Float  { return String(format: "%.4f", f) }
                    return "\(v)"
                }
                print("  " + vals.joined(separator: "\t"))
            }
            if df.rows.count > 30 { print("  … \(df.rows.count - 30) more rows (use --json for full output)") }
        }
    }
}

struct APError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}
