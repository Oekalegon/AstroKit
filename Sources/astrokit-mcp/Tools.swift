import Foundation
import AstrophotoArchiveKit
import AstrophotoKit
import Metal
import TabularData

struct Tools {

    // MARK: - Tool definitions (returned to MCP clients via tools/list)

    static let definitions: [[String: Any]] = [
        [
            "name": "get_version",
            "description": "Return the astrokit-mcp server version string.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ] as [String: Any],
        ],
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
            "description": "Execute an astrophoto pipeline on one or more FITS files and return the analysis results. Frames can be supplied from the archive via input_frameset_id. Use input_paths (array) for ad-hoc multi-frame pipelines such as frame_registration.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pipeline_id": [
                        "type": "string",
                        "description": "Pipeline ID to run (e.g. 'star_detection', 'frame_registration').",
                    ],
                    "input_frameset_id": [
                        "type": "string",
                        "description": "UUID of an archive FrameSet to use as input (from archive_frameset_list or archive_frameset_create). Takes precedence over input_dir, input_paths, and input_path.",
                    ],
                    "input_frame_id": [
                        "type": "string",
                        "description": "UUID of a single archive frame to use as input (from archive_find or archive_get). For single-frame pipelines such as star_detection, optical_quality, and collimation. Takes precedence over input_path.",
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
        case "get_version":      return "astrokit-mcp \(Version.string)"
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

        // Build pipeline inputs — support archive frame/frameset, directory, array, or single path
        let inputFrameSetID = arguments["input_frameset_id"] as? String
        let inputFrameID    = arguments["input_frame_id"]    as? String
        let inputDir        = arguments["input_dir"]         as? String
        let inputPaths      = arguments["input_paths"]       as? [String]
        let inputPath       = arguments["input_path"]        as? String
        let inputName       = arguments["input_name"]        as? String

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

        if let frameSetID = inputFrameSetID {
            guard let uuid = UUID(uuidString: frameSetID) else {
                throw ToolError("input_frameset_id must be a valid UUID: \(frameSetID)")
            }
            let config = try ArchiveConfiguration.fromEnvironment()
            let archive = try Archive(configuration: config)
            guard try await archive.frameSet(id: uuid) != nil else {
                throw ToolError("No frame set with id '\(frameSetID)' found in archive.")
            }
            let archivedFrames = try await archive.frames(inFrameSet: uuid)
            guard !archivedFrames.isEmpty else {
                throw ToolError("Frame set '\(frameSetID)' contains no frames.")
            }
            let resolvedName: String
            if let name = inputName {
                resolvedName = name
            } else if expectedInputs.count == 1 {
                resolvedName = expectedInputs[0]
            } else {
                throw ToolError("Multiple pipeline inputs detected; specify input_name.")
            }
            var frames: [Frame] = []
            for af in archivedFrames {
                guard FileManager.default.fileExists(atPath: af.filePath) else {
                    throw ToolError("Archive frame file not found on disk: \(af.filePath)")
                }
                let fitsFile = try FITSFile(path: af.filePath)
                let img = try fitsFile.readFITSImage()
                let frame = try Frame(fitsImage: img, device: device, filePath: af.filePath)
                frames.append(frame)
            }
            pipelineInputs[resolvedName] = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])
        } else if let frameID = inputFrameID {
            guard let uuid = UUID(uuidString: frameID) else {
                throw ToolError("input_frame_id must be a valid UUID: \(frameID)")
            }
            let config = try ArchiveConfiguration.fromEnvironment()
            let archive = try Archive(configuration: config)
            guard let af = try await archive.frame(id: uuid) else {
                throw ToolError("No frame with id '\(frameID)' found in archive.")
            }
            guard FileManager.default.fileExists(atPath: af.filePath) else {
                throw ToolError("Archive frame file not found on disk: \(af.filePath)")
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
            let fitsFile = try FITSFile(path: af.filePath)
            let img = try fitsFile.readFITSImage()
            pipelineInputs[resolvedName] = try Frame(fitsImage: img, device: device, filePath: af.filePath)
        } else if let paths = resolvedPaths ?? inputPaths, !paths.isEmpty {
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
            throw ToolError(
                "Provide input_frameset_id (archive FrameSet), input_frame_id (archive frame), " +
                "input_path (single file), input_paths (array), or input_dir (directory) for pipeline '\(pipelineID)'."
            )
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

        // Auto-archive result frames when an archive is configured.
        if !frames.isEmpty {
            let archiveNote = await autoArchiveResults(
                frames: frames,
                pipelineID: pipelineID,
                parameters: parameters,
                pipelineInputs: pipelineInputs,
                existingOutputPath: (outputPath?.hasSuffix(".fits") == true || outputPath?.hasSuffix(".fit") == true) ? outputPath : nil
            )
            if let note = archiveNote { savedNote += "\n\(note)" }
        }

        // Back-update quality metrics on the input frame (analysis pipelines only).
        // We identify the input archive frame from input_frame_id or by file path lookup.
        if let qualityNote = await backUpdateQuality(
            tables: tables,
            inputFrameID: inputFrameID.flatMap { UUID(uuidString: $0) },
            inputFilePath: inputPath
        ) {
            savedNote += "\n\(qualityNote)"
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

    private func autoArchiveResults(
        frames: [Frame],
        pipelineID: String,
        parameters: [String: Parameter],
        pipelineInputs: [String: Any],
        existingOutputPath: String?
    ) async -> String? {
        guard let config = try? ArchiveConfiguration.fromEnvironment() else { return nil }

        do {
            let archive = try Archive(configuration: config)

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
                    // Reference frame (pos 0) provides pointing and observation date.
                    if pos == 0 {
                        refRA  = af?.ra
                        refDec = af?.dec
                    }
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
            let refDate  = timestamps.max().flatMap { iso8601.string(from: $0) }   // newest = reference frame
            let dateBeg  = timestamps.min().flatMap { iso8601.string(from: $0) }
            let dateEnd  = timestamps.max().flatMap { iso8601.string(from: $0) }

            let paramMap = parameters.reduce(into: [String: String]()) { $0[$1.key] = $1.value.stringValue }
            let run = try await archive.recordProcessingRun(
                pipelineID: pipelineID, parameters: paramMap, inputs: runInputs
            )

            var archivedIDs: [String] = []
            for frame in frames {
                guard let texture = frame.texture else { continue }
                let w = texture.width, h = texture.height
                var pixels = [Float](repeating: 0, count: w * h)
                texture.getBytes(&pixels,
                                 bytesPerRow: w * MemoryLayout<Float>.size,
                                 from: MTLRegionMake2D(0, 0, w, h),
                                 mipmapLevel: 0)

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

                let (archived, _) = try await archive.add(fitsFile: fileToArchive, processingRunID: run.id)
                if let tmp = tempURL { try? FileManager.default.removeItem(at: tmp) }
                archivedIDs.append(archived.id.uuidString)
            }

            if archivedIDs.isEmpty { return "Auto-archive: no frames could be read from GPU texture." }
            return "Archived result frame(s): \(archivedIDs.joined(separator: ", ")) (run: \(run.id))"
        } catch {
            return "Auto-archive failed: \(error.localizedDescription)"
        }
    }

    /// Extracts quality metrics from pipeline output tables and stores them on the input archive
    /// frame(s). Handles two cases:
    ///
    /// **Per-frame** (frame_registration / frame_stacking): the registration table has one row per
    /// input frame with `file_path`, `star_count`, and `median_fwhm` columns. Each row is matched
    /// directly to an archive frame by its file path.
    ///
    /// **Single-frame** (star_detection / optical_quality / autofocus_focused): looks for a
    /// `pixel_coordinates` table (star count), a `median_fwhm` summary table, and a
    /// `background_level` table. The result is applied to the frame identified by `inputFrameID`
    /// or `inputFilePath`.
    private func backUpdateQuality(
        tables: [TableData],
        inputFrameID: UUID?,
        inputFilePath: String?
    ) async -> String? {
        guard let config = try? ArchiveConfiguration.fromEnvironment() else { return nil }
        guard let archive = try? Archive(configuration: config) else { return nil }

        // 1. Per-frame path: registration table produced by frame_registration / frame_stacking.
        let perFrame = Self.extractPerFrameQuality(from: tables)
        if !perFrame.isEmpty {
            var notes: [String] = []
            do {
                for entry in perFrame {
                    let expanded = (entry.filePath as NSString).expandingTildeInPath
                    guard let af = try await archive.frame(filePath: expanded) else { continue }
                    try await archive.updateFrameQuality(
                        id: af.id,
                        starCount: entry.starCount,
                        medianFWHM: entry.medianFWHM,
                        backgroundNoise: nil,
                        medianEccentricity: entry.medianEccentricity
                    )
                    var parts: [String] = []
                    if let v = entry.starCount         { parts.append("stars: \(v)") }
                    if let v = entry.medianFWHM        { parts.append(String(format: "FWHM: %.2fpx", v)) }
                    if let v = entry.medianEccentricity { parts.append(String(format: "ecc: %.3f", v)) }
                    if !parts.isEmpty { notes.append("\(af.id): \(parts.joined(separator: ", "))") }
                }
            } catch {
                return "Quality update failed: \(error.localizedDescription)"
            }
            return notes.isEmpty ? nil : "Quality metrics stored on \(notes.count) frame(s)."
        }

        // 2. Single-frame path: summary tables from analysis pipelines.
        let metrics = Self.extractGlobalQuality(from: tables)
        guard metrics.starCount != nil || metrics.medianFWHM != nil || metrics.backgroundNoise != nil || metrics.medianEccentricity != nil else {
            return nil
        }
        do {
            let targetID: UUID?
            if let id = inputFrameID {
                targetID = id
            } else if let path = inputFilePath {
                let expanded = (path as NSString).expandingTildeInPath
                targetID = try await archive.frame(filePath: expanded)?.id
            } else {
                targetID = nil
            }
            guard let id = targetID else { return nil }
            try await archive.updateFrameQuality(
                id: id,
                starCount: metrics.starCount,
                medianFWHM: metrics.medianFWHM,
                backgroundNoise: metrics.backgroundNoise,
                medianEccentricity: metrics.medianEccentricity
            )
            var parts: [String] = []
            if let v = metrics.starCount          { parts.append("stars: \(v)") }
            if let v = metrics.medianFWHM         { parts.append(String(format: "FWHM: %.2fpx", v)) }
            if let v = metrics.backgroundNoise    { parts.append(String(format: "bg: %.4f", v)) }
            if let v = metrics.medianEccentricity { parts.append(String(format: "ecc: %.3f", v)) }
            return "Quality metrics stored on frame \(id): \(parts.joined(separator: ", "))."
        } catch {
            return "Quality update failed: \(error.localizedDescription)"
        }
    }

    /// Extracts per-frame quality metrics from a registration table.
    ///
    /// Identified by having `file_path`, `median_fwhm`, and `star_count` columns (produced by
    /// `FrameRegistrationProcessor` inside frame_registration and frame_stacking pipelines).
    /// `sky_noise` is not mapped to `backgroundNoise` because it is in ADU, not normalised 0–1.
    static func extractPerFrameQuality(
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
    ///
    /// - `pixel_coordinates` (has `centroid_x`/`centroid_y`): row count → `starCount`
    /// - `median_fwhm` summary table (has `sigma_clipped_mean_fwhm_major/minor`): → `medianFWHM`
    /// - `background_level` table: → `backgroundNoise` (normalised 0–1)
    static func extractGlobalQuality(
        from tables: [TableData]
    ) -> (starCount: Int?, medianFWHM: Double?, backgroundNoise: Double?, medianEccentricity: Double?) {
        var starCount: Int? = nil
        var medianFWHM: Double? = nil
        var backgroundNoise: Double? = nil
        var medianEccentricity: Double? = nil

        for table in tables {
            guard let df = table.dataFrame else { continue }
            let colNames = Set(df.columns.map { $0.name })

            // Per-star table: star count + mean eccentricity from individual measurements.
            if colNames.contains("centroid_x") && colNames.contains("centroid_y") {
                starCount = df.rows.count
                let eccs = df.rows.compactMap { $0["eccentricity"] as? Double }.filter { !$0.isNaN }
                if !eccs.isEmpty { medianEccentricity = eccs.reduce(0, +) / Double(eccs.count) }
            }
            // FWHM summary table (from FWHMProcessor / star_detection).
            if colNames.contains("sigma_clipped_mean_fwhm_major"),
               colNames.contains("sigma_clipped_mean_fwhm_minor"),
               let row = df.rows.first,
               let major = row["sigma_clipped_mean_fwhm_major"] as? Double,
               let minor = row["sigma_clipped_mean_fwhm_minor"] as? Double,
               major > 0 {
                medianFWHM = (major + minor) / 2.0
            }
            // Background level table (from background_estimation).
            if colNames.contains("background_level"),
               let row = df.rows.first,
               let level = row["background_level"] as? Double {
                backgroundNoise = level
            }
            // Global eccentricity summary (from optical_quality pipeline).
            if colNames.contains("global_mean_eccentricity"),
               let row = df.rows.first,
               let ecc = row["global_mean_eccentricity"] as? Double {
                medianEccentricity = ecc
            }
        }
        return (starCount, medianFWHM, backgroundNoise, medianEccentricity)
    }

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
