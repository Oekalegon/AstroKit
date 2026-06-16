import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Recent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List recently archived frames, newest first."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Option(name: [.short, .customLong("count")],
            help: "Number of items to show (default: 15); 0 or negative shows all.")
    var count: Int = 15

    @Flag(name: .long, help: "Show recent activity grouped by session (raw frames → session, processed frames and framesets shown individually).")
    var sessions: Bool = false

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        let limit   = count > 0 ? count : nil

        if sessions {
            let items = try await archive.recentActivity(limit: limit)
            if json { printJSON(items) } else { printTable(items) }
        } else {
            let frames = try await archive.recentFrames(limit: limit)
            if json { printJSON(frames) } else { printTable(frames) }
        }
    }

    // MARK: - Activity table

    private func printTable(_ entries: [RecentEntry]) {
        if entries.isEmpty {
            print("No recent activity in archive.")
            return
        }
        let iso = ISO8601DateFormatter()
        func shortDate(_ date: Date) -> String {
            String(iso.string(from: date).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }

        print("Recent archive activity (\(entries.count)):\n")
        var table = TextTable(columns: [
            .init("ID"),
            .init("Date"),
            .init("Kind"),
            .init("Name / File"),
            .init("Count", .right),
        ])
        for entry in entries {
            switch entry {
            case .session(let s, let recency):
                let kind = "session·\(s.isNight ? "night" : "day")"
                table.addRow([s.id.uuidString, shortDate(recency), kind, s.name, "\(s.frameCount)"])
            case .dateGroup(let label, let utcDate, _, let count):
                table.addRow(["-", utcDate, "raw·light", label, "\(count)"])
            case .frame(let f):
                let kind = "\(f.processingLevel.rawValue)·\(f.frameType)"
                let name = (f.filePath as NSString).lastPathComponent
                table.addRow([f.id.uuidString, shortDate(f.addedAt), kind, name, ""])
            case .frameSet(let fs):
                table.addRow([fs.id.uuidString, shortDate(fs.createdAt), "frameset", fs.name, "\(fs.frameCount)"])
            }
        }
        print(table.render())
    }

    // MARK: - Activity JSON

    private func printJSON(_ entries: [RecentEntry]) {
        let iso = ISO8601DateFormatter()
        let dicts: [[String: Any]] = entries.map { entry in
            switch entry {
            case .session(let s, let recency):
                var d: [String: Any] = [
                    "kind":        "session",
                    "id":          s.id.uuidString,
                    "name":        s.name,
                    "is_night":    s.isNight,
                    "latitude":    s.latitude,
                    "longitude":   s.longitude,
                    "frame_count": s.frameCount,
                    "recency":     iso.string(from: recency),
                ]
                if let v = s.startTime { d["start_time"] = iso.string(from: v) }
                if let v = s.endTime   { d["end_time"]   = iso.string(from: v) }
                return d
            case .dateGroup(let label, let utcDate, let recency, let count):
                return [
                    "kind":        "date_group",
                    "name":        label,
                    "utc_date":    utcDate,
                    "frame_count": count,
                    "recency":     iso.string(from: recency),
                ]
            case .frame(let f):
                var d: [String: Any] = [
                    "kind":             "frame",
                    "id":               f.id.uuidString,
                    "file_path":        f.filePath,
                    "frame_type":       f.frameType,
                    "processing_level": f.processingLevel.rawValue,
                    "added_at":         iso.string(from: f.addedAt),
                ]
                if let v = f.objectName   { d["object_name"]  = v }
                if let v = f.filter       { d["filter"]        = v }
                if let v = f.camera       { d["camera"]        = v }
                if let v = f.exposureTime { d["exposure_time"] = v }
                if let v = f.timestamp    { d["timestamp"]     = iso.string(from: v) }
                return d
            case .frameSet(let fs):
                var d: [String: Any] = [
                    "kind":             "frameset",
                    "id":               fs.id.uuidString,
                    "name":             fs.name,
                    "frame_type":       fs.frameType,
                    "processing_level": fs.processingLevel.rawValue,
                    "frame_count":      fs.frameCount,
                    "created_at":       iso.string(from: fs.createdAt),
                ]
                if let v = fs.objectName { d["object_name"] = v }
                if let v = fs.filter     { d["filter"]       = v }
                return d
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    // MARK: - Frames table

    private func printTable(_ frames: [ArchivedFrame]) {
        if frames.isEmpty {
            print("No frames in archive.")
            return
        }
        let iso = ISO8601DateFormatter()
        func shortDate(_ date: Date) -> String {
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

    // MARK: - Frames JSON

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
