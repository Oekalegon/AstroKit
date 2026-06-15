import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show all stored information for a single archive frame."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Frame UUID (from ap-archive find).")
    var id: String

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("'\(id)' is not a valid UUID.")
        }
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        guard let frame = try await archive.frame(id: uuid) else {
            throw ValidationError("No frame with id \(id) found in the archive.")
        }
        let provenance = try await archive.processingRun(for: frame)

        if json {
            printJSON(frame, provenance: provenance)
        } else {
            print(formatted(frame, provenance: provenance))
        }
    }

    // MARK: - Formatting

    private func formatted(_ f: ArchivedFrame, provenance: (run: ArchivedProcessingRun, inputs: [ProcessingRunInputRef])?) -> String {
        let iso = ISO8601DateFormatter()
        func row(_ label: String, _ value: String) -> String {
            String(format: "  %-18@ %@", (label + ":") as NSString, value)
        }
        func opt(_ label: String, _ value: String?) -> String? {
            value.map { row(label, $0) }
        }

        var lines: [String] = []
        lines.append("Frame  \(f.id.uuidString)")
        lines.append(String(repeating: "─", count: 60))

        lines.append(row("Type", f.frameType))
        if let v = f.objectName   { lines.append(row("Object",       v)) }
        if let v = f.filter       { lines.append(row("Filter",       v)) }
        if let v = f.exposureTime { lines.append(row("Exposure",     String(format: "%.0f s", v))) }
        if let sid = f.sessionID {
            if let beg = f.sessionBeg, let end = f.sessionEnd {
                let fmt = { (d: Date) in String(iso.string(from: d).prefix(19)) }
                lines.append(row("Session", "\(sid.uuidString)  (\(fmt(beg)) → \(fmt(end)) UTC)"))
            } else {
                lines.append(row("Session", sid.uuidString))
            }
        } else if let v = f.timestamp {
            lines.append(row("Date",         iso.string(from: v)))
        }

        lines.append("")
        var hasCameraSection = false
        if let v = f.camera      { lines.append(row("Camera",       v));                        hasCameraSection = true }
        if let v = f.gain        { lines.append(row("Gain",         String(format: "%.0f", v))); hasCameraSection = true }
        if let v = f.offset      { lines.append(row("Offset",       String(format: "%.0f", v))); hasCameraSection = true }
        if let v = f.egain       { lines.append(row("EGAIN",        String(format: "%.4f e⁻/ADU", v))); hasCameraSection = true }
        if let lo = f.temperatureMin, let hi = f.temperatureMax, abs(hi - lo) > 0.05 {
            lines.append(row("Temperature",  String(format: "%.1f … %.1f °C", lo, hi))); hasCameraSection = true
        } else if let v = f.temperature {
            lines.append(row("Temperature",  String(format: "%.1f °C", v))); hasCameraSection = true
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
        lines.append(row("Added at",   iso.string(from: f.addedAt)))
        lines.append(row("File",       f.filePath))

        let hasQuality = f.starCount != nil || f.medianFWHM != nil || f.medianEccentricity != nil
            || f.backgroundNoise != nil || f.saturatedStarCount != nil || f.hotPixelCount != nil
        if hasQuality {
            lines.append("")
            lines.append("Quality metrics")
            lines.append(String(repeating: "─", count: 60))
            if let v = f.starCount {
                let satStr = f.saturatedStarCount.map { "  (\($0) saturated)" } ?? ""
                lines.append(row("Stars", "\(v)\(satStr)"))
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

    private func printJSON(_ f: ArchivedFrame, provenance: (run: ArchivedProcessingRun, inputs: [ProcessingRunInputRef])?) {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id":               f.id.uuidString,
            "file_path":        f.filePath,
            "frame_type":       f.frameType,
            "processing_level": f.processingLevel.rawValue,
            "calibrated":       f.calibrated,
            "stacked":          f.stacked,
            "stretched":        f.stretched,
            "added_at":         iso.string(from: f.addedAt),
        ]
        if let v = f.objectName   { d["object_name"]   = v }
        if let v = f.ra           { d["ra"]             = v }
        if let v = f.dec          { d["dec"]            = v }
        if let v = f.healpixPixel { d["healpix_pixel"]  = v }
        if let v = f.filter       { d["filter"]         = v }
        if let v = f.camera       { d["camera"]         = v }
        if let v = f.focalLength  { d["focal_length"]   = v }
        if let v = f.pixelScale   { d["pixel_scale"]    = v }
        if let v = f.temperature  { d["temperature"]    = v }
        if let v = f.timestamp    { d["timestamp"]      = iso.string(from: v) }
        if let v = f.exposureTime { d["exposure_time"]  = v }
        if let v = f.gain         { d["gain"]           = v }
        if let v = f.offset       { d["offset"]         = v }
        if let v = f.width        { d["width"]          = v }
        if let v = f.height       { d["height"]         = v }
        if let v = f.bitpix       { d["bitpix"]         = v }
        d["rejected"] = f.rejected
        if let v = f.rejectedReason { d["rejected_reason"] = v }
        if let v = f.egain                    { d["egain"]                       = v }
        if let v = f.starCount                { d["star_count"]                  = v }
        if let v = f.saturatedStarCount       { d["saturated_star_count"]        = v }
        if let v = f.medianFWHM               { d["median_fwhm"]                 = v }
        if let v = f.medianFWHMArcsec         { d["median_fwhm_arcsec"]          = v }
        if let v = f.medianEccentricity       { d["median_eccentricity"]         = v }
        if let v = f.backgroundNoise          { d["background_noise"]            = v }
        if let v = f.backgroundNoiseElectrons { d["background_noise_electrons"]  = v }
        if let v = f.hotPixelCount            { d["hot_pixel_count"]             = v }

        if let (run, inputs) = provenance {
            var runDict: [String: Any] = [
                "id":          run.id.uuidString,
                "pipeline_id": run.pipelineID,
                "created_at":  iso.string(from: run.createdAt),
            ]
            if !run.parameters.isEmpty { runDict["parameters"] = run.parameters }
            if !inputs.isEmpty {
                runDict["inputs"] = inputs.map { ref -> [String: Any] in
                    var r: [String: Any] = [
                        "input_name": ref.inputName,
                        "position":   ref.position,
                    ]
                    if let v = ref.frameID  { r["frame_id"]  = v.uuidString }
                    if let v = ref.filePath { r["file_path"] = v }
                    return r
                }
            }
            d["processing_run"] = runDict
        }

        if let data = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
