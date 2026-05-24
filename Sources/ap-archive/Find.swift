import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the archive for frames matching a query."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Option(name: .long, help: "Filter by object name (partial match).")
    var object: String?

    @Option(name: .long, help: "Frame types to include, comma-separated (light,dark,flat,bias).")
    var type: String?

    @Option(name: .long, help: "Filters to include, comma-separated (Ha,SII,OIII,R,G,B,L).")
    var filter: String?

    @Option(name: .long, help: "Start date (ISO8601, e.g. 2024-01-01).")
    var from: String?

    @Option(name: .long, help: "End date (ISO8601, e.g. 2024-12-31).")
    var to: String?

    @Option(name: .long, help: "Processing level (raw, calibrated, stacked, stretched).")
    var level: String?

    @Flag(name: .long, help: "Only calibrated frames.")
    var calibrated: Bool = false

    @Flag(name: .long, help: "Only stacked frames.")
    var stacked: Bool = false

    @Option(name: .long, help: "Cone search RA in degrees.")
    var ra: Double?

    @Option(name: .long, help: "Cone search Dec in degrees.")
    var dec: Double?

    @Option(name: .long, help: "Cone search radius in degrees.")
    var radius: Double?

    @Option(name: .long, help: "Maximum number of results.")
    var limit: Int?

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        var query = FrameQuery()
        query.objectName = object
        query.limit = limit

        if let t = type {
            query.frameTypes = t.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if let f = filter {
            query.filters = f.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if let lvl = level {
            query.processingLevel = ProcessingLevel(rawValue: lvl)
        }
        if calibrated { query.calibrated = true }
        if stacked    { query.stacked    = true }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        if let fromStr = from, let toStr = to,
           let fromDate = df.date(from: fromStr), let toDate = df.date(from: toStr) {
            query.dateRange = DateInterval(start: fromDate, end: toDate)
        }

        if let ra, let dec, let radius {
            query.coneSearch = FrameQuery.ConeSearch(ra: ra, dec: dec, radiusDeg: radius)
        }

        let frames = try await archive.frames(matching: query)

        if json {
            printJSON(frames)
        } else {
            printTable(frames)
        }
    }

    private func printTable(_ frames: [ArchivedFrame]) {
        if frames.isEmpty {
            print("No frames found.")
            return
        }
        print("Found \(frames.count) frame(s):\n")
        let header = String(format: "%-36s  %-14s  %-8s  %-8s  %8s  %s",
            "ID", "Object", "Type", "Filter", "Exposure", "File")
        print(header)
        print(String(repeating: "-", count: header.count))
        for f in frames {
            let obj      = f.objectName ?? "-"
            let type_    = f.frameType
            let filt     = f.filter ?? "-"
            let exp      = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
            let file     = (f.filePath as NSString).lastPathComponent
            print(String(format: "%-36s  %-14s  %-8s  %-8s  %8s  %s",
                f.id.uuidString, obj, type_, filt, exp, file))
        }
    }

    private func printJSON(_ frames: [ArchivedFrame]) {
        let iso = ISO8601DateFormatter()
        let dicts: [[String: Any]] = frames.map { f in
            var d: [String: Any] = [
                "id": f.id.uuidString,
                "file_path": f.filePath,
                "frame_type": f.frameType,
                "processing_level": f.processingLevel.rawValue,
            ]
            if let v = f.objectName   { d["object_name"]   = v }
            if let v = f.ra           { d["ra"]             = v }
            if let v = f.dec          { d["dec"]            = v }
            if let v = f.filter       { d["filter"]         = v }
            if let v = f.exposureTime { d["exposure_time"]  = v }
            if let v = f.timestamp    { d["timestamp"]      = iso.string(from: v) }
            if let v = f.camera       { d["camera"]         = v }
            if let v = f.temperature  { d["temperature"]    = v }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
