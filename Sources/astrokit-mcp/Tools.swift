import Foundation
import AstrophotoKit
import Metal
import TabularData

struct Tools {

    // MARK: - Tool definitions (returned to MCP clients via tools/list)

    static let definitions: [[String: Any]] = [
        [
            "name": "list_pipelines",
            "description": "List all available astrophoto processing pipelines with their IDs and descriptions.",
            "inputSchema": [
                "type": "object",
                "properties": [String: String](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "inspect_pipeline",
            "description": "Get detailed information about a pipeline: required inputs, tunable parameters, and processing steps.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pipeline_id": [
                        "type": "string",
                        "description": "The pipeline ID to inspect (e.g. 'star_detection').",
                    ],
                ] as [String: Any],
                "required": ["pipeline_id"],
            ] as [String: Any],
        ],
        [
            "name": "run_pipeline",
            "description": "Execute an astrophoto pipeline on one or more FITS files and return the analysis results. Use input_paths (array) for multi-frame pipelines such as frame_registration.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pipeline_id": [
                        "type": "string",
                        "description": "Pipeline ID to run (e.g. 'star_detection', 'frame_registration').",
                    ],
                    "input_path": [
                        "type": "string",
                        "description": "Absolute path to a single input FITS file (single-frame pipelines).",
                    ],
                    "input_paths": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Array of absolute FITS file paths for multi-frame pipelines (e.g. frame_registration). Takes precedence over input_path.",
                    ],
                    "input_dir": [
                        "type": "string",
                        "description": "Absolute path to a directory containing FITS files. All .fits/.fit/.fts files are loaded as a FrameSet (sorted by filename). Takes precedence over input_paths and input_path.",
                    ],
                    "input_name": [
                        "type": "string",
                        "description": "Pipeline input name. Omit for single-input pipelines (auto-detected).",
                    ],
                    "parameters": [
                        "type": "object",
                        "description": "Optional pipeline parameters as key-value pairs. Use inspect_pipeline to see available parameters.",
                    ],
                    "output_path": [
                        "type": "string",
                        "description": "Optional file path to save the output. For stacking pipelines (e.g. frame_stacking) this writes a FITS file containing the stacked image and registration table. For analysis pipelines (e.g. frame_registration) it writes the result table. Use .csv extension with output_format=csv for a plain-text table.",
                    ],
                    "output_format": [
                        "type": "string",
                        "enum": ["fits", "csv"],
                        "description": "Output file format: 'fits' (BINTABLE, default) or 'csv'.",
                    ],
                ] as [String: Any],
                "required": ["pipeline_id"],
            ] as [String: Any],
        ],
    ]

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "list_pipelines":   return listPipelines()
        case "inspect_pipeline": return try inspectPipeline(id: required(arguments, "pipeline_id"))
        case "run_pipeline":     return try await runPipeline(arguments: arguments)
        default:                 throw ToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool implementations

    private func listPipelines() -> String {
        let all = PipelineRegistry.shared.getAll()
        guard !all.isEmpty else { return "No pipelines registered." }
        var lines = ["Available pipelines (\(all.count)):"]
        for p in all.values.sorted(by: { $0.id < $1.id }) {
            lines.append("• \(p.id)\(p.description.map { ": \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    private func inspectPipeline(id: String) throws -> String {
        guard let pipeline = PipelineRegistry.shared.get(id: id) else {
            throw ToolError("Pipeline not found: '\(id)'. Call list_pipelines to see what's available.")
        }

        let inputNames = Array(Set(pipeline.steps.flatMap { step in
            step.dataInputs.compactMap { di in di.from.contains(".") ? nil : di.from }
        })).sorted()

        let paramSpecs: [String: ParameterSpec] = pipeline.steps
            .flatMap { $0.parameters }
            .filter { $0.from != nil }
            .reduce(into: [:]) { acc, spec in if acc[spec.from!] == nil { acc[spec.from!] = spec } }

        var lines = [
            "Pipeline: \(pipeline.id)",
            "Name: \(pipeline.name)",
        ]
        if let desc = pipeline.description { lines.append("Description: \(desc)") }
        lines.append("")
        lines.append("Inputs (\(inputNames.count)): \(inputNames.joined(separator: ", "))")
        lines.append("Steps: \(pipeline.steps.count)")

        if !paramSpecs.isEmpty {
            lines.append("")
            lines.append("Parameters:")
            for key in paramSpecs.keys.sorted() {
                let spec = paramSpecs[key]!
                let def = spec.defaultValue.map { " [default: \($0.stringValue)]" } ?? " [required]"
                let desc = spec.description.map { " — \($0)" } ?? ""
                lines.append("  \(key)\(def)\(desc)")
            }
        }

        lines.append("")
        lines.append("Steps:")
        for step in pipeline.steps {
            lines.append("  \(step.id) — \(step.type)\(step.name.map { " (\($0))" } ?? "")")
        }

        return lines.joined(separator: "\n")
    }

    private func runPipeline(arguments: [String: Any]) async throws -> String {
        let pipelineID: String = try required(arguments, "pipeline_id")
        let outputPath  = arguments["output_path"]  as? String
        let outputFormat = arguments["output_format"] as? String ?? "fits"

        guard let pipeline = PipelineRegistry.shared.get(id: pipelineID) else {
            throw ToolError("Pipeline not found: '\(pipelineID)'. Call list_pipelines first.")
        }

        let expectedInputs = Array(Set(pipeline.steps.flatMap { step in
            step.dataInputs.compactMap { di in di.from.contains(".") ? nil : di.from }
        }))

        guard let device = AstrophotoKit.makeDefaultDevice() else {
            throw ToolError("No Metal GPU device available.")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw ToolError("Failed to create Metal command queue.")
        }

        // Convert params to Parameter values
        let params = arguments["parameters"] as? [String: Any] ?? [:]
        var parameters: [String: Parameter] = [:]
        for (key, val) in params {
            switch val {
            case let i as Int:    parameters[key] = .int(i)
            case let d as Double: parameters[key] = .double(d)
            case let s as String:
                if let i = Int(s)         { parameters[key] = .int(i) }
                else if let d = Double(s) { parameters[key] = .double(d) }
                else                      { parameters[key] = .string(s) }
            default: parameters[key] = .string("\(val)")
            }
        }

        // Build pipeline inputs — support directory, array, or single path
        let inputDir    = arguments["input_dir"]   as? String
        let inputPaths  = arguments["input_paths"] as? [String]
        let inputPath   = arguments["input_path"]  as? String
        let inputName   = arguments["input_name"]  as? String

        // Resolve input_dir → sorted list of FITS paths
        let resolvedPaths: [String]? = try {
            guard let dir = inputDir else { return nil }
            let expanded = (dir as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                throw ToolError("input_dir not found or is not a directory: \(dir)")
            }
            let extensions = Set(["fits", "fit", "fts"])
            let files = try FileManager.default.contentsOfDirectory(atPath: expanded)
            let fits = files
                .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
                .map { (expanded as NSString).appendingPathComponent($0) }
            guard !fits.isEmpty else {
                throw ToolError("No FITS files found in directory: \(dir)")
            }
            return fits
        }()

        var pipelineInputs: [String: Any] = [:]

        if let paths = resolvedPaths ?? inputPaths, !paths.isEmpty {
            // Multi-frame input → FrameSet
            let resolvedName: String
            if let name = inputName {
                resolvedName = name
            } else if expectedInputs.count == 1 {
                resolvedName = expectedInputs[0]
            } else {
                throw ToolError("Multiple pipeline inputs detected; specify input_name.")
            }
            var frames: [Frame] = []
            for path in paths {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else {
                    throw ToolError("File not found: \(path)")
                }
                let fitsFile = try FITSFile(path: expanded)
                let img = try fitsFile.readFITSImage()
                let frame = try Frame(fitsImage: img, device: device, filePath: expanded)
                frames.append(frame)
            }
            pipelineInputs[resolvedName] = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])
        } else if let path = inputPath {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ToolError("File not found: \(path)")
            }
            let resolvedName: String
            if let name = inputName {
                resolvedName = name
            } else if expectedInputs.count == 1 {
                resolvedName = expectedInputs[0]
            } else {
                throw ToolError(
                    "Pipeline '\(pipelineID)' has multiple inputs: \(expectedInputs.sorted().joined(separator: ", ")). " +
                    "Specify input_name."
                )
            }
            let fitsFile = try FITSFile(path: expanded)
            pipelineInputs[resolvedName] = try fitsFile.readFITSImage()
        } else {
            throw ToolError("Provide input_path (single file) or input_paths (array) for pipeline '\(pipelineID)'.")
        }

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
        var savedNote = ""
        if let outPath = outputPath {
            if let firstFrame = frames.first, let firstTable = tables.first,
               let df = firstTable.dataFrame, outputFormat.lowercased() != "csv" {
                // Stacked image + registration table → combined FITS
                guard let texture = firstFrame.texture else {
                    throw ToolError("Output frame has no texture data")
                }
                let w = texture.width, h = texture.height
                var pixels = [Float](repeating: 0, count: w * h)
                texture.getBytes(&pixels,
                                 bytesPerRow: w * MemoryLayout<Float>.size,
                                 from: MTLRegionMake2D(0, 0, w, h),
                                 mipmapLevel: 0)
                let stackMethod  = parameters["method"]?.stringValue         ?? "average"
                let stackNorm    = parameters["normalisation"]?.stringValue   ?? "none"
                let stackRej     = parameters["pixel_rejection"]?.stringValue ?? "sigma_clip"
                let stackRejLow  = parameters["rejection_low"]?.doubleValue   ?? 3.0
                let stackRejHigh = parameters["rejection_high"]?.doubleValue  ?? 3.0
                try FITSTableWriter.writeStackedOutput(
                    pixelData: pixels, width: w, height: h,
                    registrationTable: df,
                    method: stackMethod,
                    normalisation: stackNorm,
                    rejection: stackRej,
                    rejectionLow: stackRejLow,
                    rejectionHigh: stackRejHigh,
                    to: outPath
                )
                let inputFrameSet = pipelineInputs.values.compactMap { $0 as? FrameSet }.first
                let stackSummary = stackSummaryLine(pixels: pixels, registrationTable: df,
                                                    inputFrameSet: inputFrameSet)
                savedNote = "\nSaved stacked FITS to \(outPath).\(stackSummary.map { "\n\($0)" } ?? "")"
            } else if let firstTable = tables.first, let df = firstTable.dataFrame {
                let fmt: FITSTableWriter.OutputFormat = (outputFormat.lowercased() == "csv") ? .csv : .fits
                try FITSTableWriter.writeRegistrationTable(df, to: outPath, format: fmt)
                savedNote = "\nSaved table to \(outPath) (\(outputFormat.lowercased()))."
            }
        }

        var lines = [
            "Pipeline '\(pipelineID)' completed in \(String(format: "%.2f", elapsed))s.",
            "\(frames.count) frame(s) produced, \(tables.count) table(s) produced.\(savedNote)",
        ]

        for (i, table) in tables.enumerated() {
            guard let df = table.dataFrame else { continue }
            let cols = df.columns.map { $0.name }
            lines.append("")
            lines.append("Table \(i + 1) — \(df.rows.count) rows, columns: \(cols.joined(separator: ", "))")
            for row in df.rows.prefix(50) {
                let entries = cols.compactMap { col -> String? in
                    guard let v = row[col] else { return nil }
                    if let d = v as? Double { return "\(col): \(String(format: "%.4f", d))" }
                    if let f = v as? Float  { return "\(col): \(String(format: "%.4f", f))" }
                    return "\(col): \(v)"
                }
                lines.append("  { \(entries.joined(separator: ", ")) }")
            }
            if df.rows.count > 50 { lines.append("  … \(df.rows.count - 50) more rows omitted.") }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func stackSummaryLine(pixels: [Float], registrationTable df: DataFrame, inputFrameSet: FrameSet?) -> String? {
        let skyNoises = df.rows.compactMap { $0["sky_noise"] as? Double }.filter { !$0.isNaN && $0 > 0 }
        guard !skyNoises.isEmpty else { return nil }

        let n = skyNoises.count
        let meanNoise     = skyNoises.reduce(0, +) / Double(n)
        let expectedNoise = meanNoise / sqrt(Double(n))

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

        var stackedNoiseADU: Double? = nil
        if let refFrame = inputFrameSet?.frames.first,
           let fitsMin  = refFrame.fitsMinValue,
           let fitsMax  = refFrame.fitsMaxValue {
            stackedNoiseADU = stackedNoiseNorm * (fitsMax - fitsMin)
        }

        let sqrtN = sqrt(Double(n))
        if let sn = stackedNoiseADU {
            return String(format: "Stack (%d frames): per-frame avg %.2f ADU  →  measured %.2f ADU  (expected %.2f, √%d=%.2f×)",
                          n, meanNoise, sn, expectedNoise, n, sqrtN)
        } else {
            return String(format: "Stack (%d frames): per-frame avg %.2f ADU  →  expected %.2f ADU  (√%d=%.2f×)",
                          n, meanNoise, expectedNoise, n, sqrtN)
        }
    }

    private func required<T>(_ args: [String: Any], _ key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError("Missing or invalid argument '\(key)'.")
        }
        return value
    }
}

struct ToolError: Error, LocalizedError {
    var errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}
