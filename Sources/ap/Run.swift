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
              ap run frame_registration --input input_frames:frame1.fits --input input_frames:frame2.fits

            Archive FrameSet input (by UUID or name):
              ap run frame_stacking --input input_frames:@frameset:3F7A1234-…
              ap run frame_stacking --input "input_frames:@frameset:M51 Ha lights"

            With parameters:
              ap run star-detection --input image.fits --param threshold_value=4.0

            Save output table:
              ap run frame_registration --input input_frames:f1.fits --input input_frames:f2.fits --output reg.fits
              ap run frame_registration ... --output reg.csv --format csv
            """
        )

        @Argument(help: "Pipeline ID to execute.")
        var pipelineID: String

        @Option(name: .shortAndLong, help: "Input FITS file or archive FrameSet. Use name:path.fits or name:@frameset:UUID. Repeat with the same name to build a FrameSet.")
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
            // A path may be a directory (expanded to FITS files) or @frameset:UUID|name (archive lookup).
            var inputPaths: [String: [String]] = [:]
            for raw in input {
                let (name, token): (String, String)
                if raw.hasPrefix("@frameset:") {
                    guard expectedInputs.count == 1 else {
                        throw ValidationError(
                            "Pipeline '\(pipelineID)' has multiple inputs. Use 'name:@frameset:ID' format.\n" +
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
                    let paths = try await archiveFrameSetPaths(ref: ref)
                    inputPaths[name, default: []].append(contentsOf: paths)
                } else {
                    inputPaths[name, default: []].append(contentsOf: try fitsFiles(at: token))
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
            var pipelineInputs: [String: Any] = [:]
            for (name, paths) in inputPaths {
                if paths.count == 1 {
                    let fitsFile = try FITSFile(path: paths[0])
                    let img = try fitsFile.readFITSImage()
                    pipelineInputs[name] = try Frame(fitsImage: img, device: device, filePath: paths[0])
                } else {
                    var frames: [Frame] = []
                    for path in paths {
                        let fitsFile = try FITSFile(path: path)
                        let img = try fitsFile.readFITSImage()
                        let frame = try Frame(fitsImage: img, device: device, filePath: path)
                        frames.append(frame)
                    }
                    pipelineInputs[name] = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])
                }
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
                if let firstFrame = frames.first, let firstTable = tables.first,
                   let df = firstTable.dataFrame, format.lowercased() != "csv" {
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
                        registrationTable: df,
                        method: stackMethod,
                        normalisation: stackNorm,
                        rejection: stackRej,
                        rejectionLow: stackRejLow,
                        rejectionHigh: stackRejHigh,
                        to: outputPath
                    )
                    if !json {
                        print("Saved stacked FITS to \(outputPath)")
                        printStackSummary(pixels: pixels, registrationTable: df,
                                          inputFrameSet: pipelineInputs["input_frames"] as? FrameSet)
                    }
                } else if let firstTable = tables.first, let df = firstTable.dataFrame {
                    // Table-only output (e.g. frame_registration)
                    let outputFormat: FITSTableWriter.OutputFormat = (format.lowercased() == "csv") ? .csv : .fits
                    try FITSTableWriter.writeRegistrationTable(df, to: outputPath, format: outputFormat)
                    if !json { print("Saved table to \(outputPath) (\(format.lowercased()))") }
                }
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

        private func archiveFrameSetPaths(ref: String) async throws -> [String] {
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
            return frames.map { $0.filePath }
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
