import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Recent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List recently archived frames, newest first."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Option(name: [.short, .customLong("count")],
            help: "Number of frames to show (default: 15); 0 or negative shows all.")
    var count: Int = 15

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        let frames  = try await archive.recentFrames(limit: count > 0 ? count : nil)

        if json {
            printJSON(frames)
        } else {
            printTable(frames)
        }
    }

    // MARK: - Table output

    private func printTable(_ frames: [ArchivedFrame]) {
        if frames.isEmpty {
            print("No frames in archive.")
            return
        }
        let iso = ISO8601DateFormatter()
        func shortDate(_ date: Date) -> String {
            // "2026-05-26 14:32" — readable but compact
            String(iso.string(from: date).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }

        print("Recently archived frames (\(frames.count)):\n")
        var table = TextTable(columns: [
            .init("ID"),
            .init("Added at"),
            .init("Type"),
            .init("Filter"),
            .init("Exposure", .right),
            .init("File"),
        ])
        for f in frames {
            let added = shortDate(f.addedAt)
            let filt  = f.filter ?? "-"
            let exp   = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
            let file  = (f.filePath as NSString).lastPathComponent
            table.addRow([f.id.uuidString, added, f.frameType, filt, exp, file])
        }
        print(table.render())
    }

    // MARK: - JSON output

    private func printJSON(_ frames: [ArchivedFrame]) {
        let iso = ISO8601DateFormatter()
        let dicts: [[String: Any]] = frames.map { f in
            var d: [String: Any] = [
                "id":               f.id.uuidString,
                "file_path":        f.filePath,
                "frame_type":       f.frameType,
                "processing_level": f.processingLevel.rawValue,
                "added_at":         iso.string(from: f.addedAt),
            ]
            if let v = f.objectName   { d["object_name"]   = v }
            if let v = f.filter       { d["filter"]         = v }
            if let v = f.camera       { d["camera"]         = v }
            if let v = f.exposureTime { d["exposure_time"]  = v }
            if let v = f.timestamp    { d["timestamp"]      = iso.string(from: v) }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
