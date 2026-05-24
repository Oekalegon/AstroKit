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

        if json {
            printJSON(frame)
        } else {
            print(formatted(frame))
        }
    }

    // MARK: - Formatting

    private func formatted(_ f: ArchivedFrame) -> String {
        let iso = ISO8601DateFormatter()
        func row(_ label: String, _ value: String) -> String {
            String(format: "  %-18s %@", (label + ":") as NSString, value)
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
        if let v = f.timestamp    { lines.append(row("Date",         iso.string(from: v))) }

        lines.append("")
        var hasCameraSection = false
        if let v = f.camera      { lines.append(row("Camera",       v));                        hasCameraSection = true }
        if let v = f.gain        { lines.append(row("Gain",         String(format: "%.0f", v))); hasCameraSection = true }
        if let v = f.offset      { lines.append(row("Offset",       String(format: "%.0f", v))); hasCameraSection = true }
        if let v = f.temperature { lines.append(row("Temperature",  String(format: "%.1f °C", v))); hasCameraSection = true }
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
        lines.append(row("Added at",   iso.string(from: f.addedAt)))
        lines.append(row("File",       f.filePath))

        return lines.joined(separator: "\n")
    }

    private func printJSON(_ f: ArchivedFrame) {
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

        if let data = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
