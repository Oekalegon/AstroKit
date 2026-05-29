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

    @Option(name: .long, help: "Camera name (exact match).")
    var camera: String?

    @Option(name: .long, help: "Frame types to include, comma-separated (light,dark,flat,bias,diagnostic).")
    var type: String?

    @Option(name: .long, help: "Filters to include, comma-separated (Hɑ,SII,OIII,R,G,B,L).")
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

    @Flag(name: .long, help: "Include rejected frames in results.")
    var includeRejected: Bool = false

    @Flag(name: .long, help: "Show only rejected frames.")
    var rejectedOnly: Bool = false

    @Option(name: .long, help: "Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded.")
    var maxFwhm: Double?

    @Option(name: .long, help: "Only frames with at least this many detected stars. Frames without quality data are excluded.")
    var minStars: Int?

    @Option(name: .long, help: "Only frames with background noise ≤ this value (0–1). Frames without quality data are excluded.")
    var maxBackgroundNoise: Double?

    @Option(name: .long, help: "Only frames with mean star eccentricity ≤ this value (0=circular). Frames without quality data are excluded.")
    var maxEccentricity: Double?

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        var query = FrameQuery()
        query.objectName = object
        query.camera = camera
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
        if rejectedOnly        { query.rejectionFilter = .onlyRejected }
        else if includeRejected { query.rejectionFilter = .includeAll }

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
        query.maxFWHM            = maxFwhm
        query.minStarCount       = minStars
        query.maxBackgroundNoise = maxBackgroundNoise
        query.maxEccentricity    = maxEccentricity

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
        let hasQuality = frames.contains { $0.starCount != nil || $0.medianFWHM != nil || $0.medianEccentricity != nil }
        print("Found \(frames.count) frame(s):\n")
        if hasQuality {
            var table = TextTable(columns: [
                .init("ID"),
                .init("Object"),
                .init("Type"),
                .init("Filter"),
                .init("Exposure", .right),
                .init("Stars", .right),
                .init("FWHM", .right),
                .init("Ecc", .right),
                .init("Rej"),
                .init("File"),
            ])
            for f in frames {
                let obj   = f.objectName ?? "-"
                let filt  = f.filter ?? "-"
                let exp   = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                let stars = f.starCount.map { "\($0)" } ?? "-"
                let fwhm: String
                if let px = f.medianFWHM {
                    if let arcsec = f.medianFWHMArcsec {
                        fwhm = String(format: "%.2fpx/%.2f\"", px, arcsec)
                    } else {
                        fwhm = String(format: "%.2fpx", px)
                    }
                } else { fwhm = "-" }
                let ecc  = f.medianEccentricity.map { String(format: "%.3f", $0) } ?? "-"
                let rej  = f.rejected ? "✗" : ""
                let file = (f.filePath as NSString).lastPathComponent
                table.addRow([f.id.uuidString, obj, f.frameType, filt, exp, stars, fwhm, ecc, rej, file])
            }
            print(table.render())
        } else {
            var table = TextTable(columns: [
                .init("ID"),
                .init("Object"),
                .init("Type"),
                .init("Filter"),
                .init("Exposure", .right),
                .init("Rej"),
                .init("File"),
            ])
            for f in frames {
                let obj  = f.objectName ?? "-"
                let filt = f.filter ?? "-"
                let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                let rej  = f.rejected ? "✗" : ""
                let file = (f.filePath as NSString).lastPathComponent
                table.addRow([f.id.uuidString, obj, f.frameType, filt, exp, rej, file])
            }
            print(table.render())
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
