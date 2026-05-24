import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add FITS file(s) to the archive."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "FITS file or directory to add.")
    var path: String

    @Flag(name: .long, help: "Recurse into subdirectories (when path is a directory).")
    var recursive: Bool = false

    @Flag(name: .long, help: "Copy files into the archive folder hierarchy.")
    var copy: Bool = false

    @Flag(name: .long, help: "Output results as JSON.")
    var json: Bool = false

    func run() async throws {
        let config = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ValidationError("Path not found: \(path)")
        }

        let added: [ArchivedFrame]
        let skippedCount: Int
        if isDir.boolValue {
            (added, skippedCount) = try await archive.add(directory: url, recursive: recursive, copyFiles: copy)
        } else {
            let (frame, isNew) = try await archive.add(fitsFile: url, copyFile: copy)
            added = isNew ? [frame] : []
            skippedCount = isNew ? 0 : 1
        }

        if json {
            printJSON(added)
        } else {
            var summary = "Added \(added.count) frame(s) to the archive."
            if skippedCount > 0 { summary += " Skipped \(skippedCount) (already in archive)." }
            print(summary)
            for frame in added {
                let filter   = frame.filter.map { " [\($0)]" } ?? ""
                let exposure = frame.exposureTime.map { String(format: " %.0fs", $0) } ?? ""
                let object   = frame.objectName.map { " \($0)" } ?? ""
                print("  \(frame.frameType)\(filter)\(exposure)\(object)  \(frame.filePath)")
            }
        }
    }

    private func printJSON(_ frames: [ArchivedFrame]) {
        let dicts = frames.map { frameToDict($0) }
        if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func frameToDict(_ f: ArchivedFrame) -> [String: Any] {
        var d: [String: Any] = [
            "id": f.id.uuidString,
            "file_path": f.filePath,
            "frame_type": f.frameType,
            "processing_level": f.processingLevel.rawValue,
            "calibrated": f.calibrated,
            "stacked": f.stacked,
            "stretched": f.stretched,
        ]
        if let v = f.objectName   { d["object_name"]   = v }
        if let v = f.ra           { d["ra"]             = v }
        if let v = f.dec          { d["dec"]            = v }
        if let v = f.filter       { d["filter"]         = v }
        if let v = f.camera       { d["camera"]         = v }
        if let v = f.exposureTime { d["exposure_time"]  = v }
        if let v = f.gain         { d["gain"]           = v }
        if let v = f.temperature  { d["temperature"]    = v }
        if let v = f.timestamp    { d["timestamp"]      = ISO8601DateFormatter().string(from: v) }
        return d
    }
}
