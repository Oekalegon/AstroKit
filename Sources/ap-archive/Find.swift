import ArgumentParser
import AstrophotoArchiveKit
import Foundation

enum SearchKind: String, ExpressibleByArgument {
    case both, frames, framesets
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the archive for frames, frame sets, or both."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Option(name: .long, help: "Filter by object name (partial match). Applies to both frames and frame sets.")
    var object: String?

    @Option(name: .long, help: "Frame type, comma-separated (light,dark,flat,bias,diagnostic). Applies to both.")
    var type: String?

    @Option(name: .long, help: "Optical filter, comma-separated (Hɑ,SII,OIII,R,G,B,L). Applies to both.")
    var filter: String?

    @Option(name: .long, help: "Processing level (raw,calibrated,stacked,stretched). Applies to both.")
    var level: String?

    @Option(name: .long, help: "Camera name, exact match. Applies to both.")
    var camera: String?

    @Option(name: .long, help: "Focal length in mm, exact match. Applies to frames.")
    var focalLength: Double?

    @Option(name: .long, help: "Start date YYYY-MM-DD. Applies to both.")
    var from: String?

    @Option(name: .long, help: "End date YYYY-MM-DD. Applies to both.")
    var to: String?

    @Option(name: .long, help: "Partial match on frame set name (frame sets only).")
    var name: String?

    // Frames-only quality filters
    @Option(name: .long, help: "Frames only: median FWHM ≤ this value (pixels).")
    var maxFwhm: Double?

    @Option(name: .long, help: "Frames only: at least this many detected stars.")
    var minStars: Int?

    @Option(name: .long, help: "Frames only: background noise ≤ this value.")
    var maxBackgroundNoise: Double?

    @Option(name: .long, help: "Frames only: mean star eccentricity ≤ this value (0=circular).")
    var maxEccentricity: Double?

    @Flag(name: .long, help: "Frames only: only stacked (master) frames. Shorthand for --level stacked.")
    var stacked: Bool = false

    // Frames-only rejection filters
    @Flag(name: .long, help: "Frames only: include rejected frames.")
    var includeRejected: Bool = false

    @Flag(name: .long, help: "Frames only: show only rejected frames.")
    var rejectedOnly: Bool = false

    // Frames-only cone search
    @Option(name: .long, help: "Frames only: cone search RA (degrees).")
    var ra: Double?

    @Option(name: .long, help: "Frames only: cone search Dec (degrees).")
    var dec: Double?

    @Option(name: .long, help: "Frames only: cone search radius (degrees).")
    var radius: Double?

    @Option(name: .long, help: "What to search: frames, framesets, or both (default: both).")
    var kind: SearchKind = .both

    @Option(name: .long, help: "Frames only: maximum number of frames to return.")
    var limit: Int?

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        let showFrames    = kind == .both || kind == .frames
        let showFrameSets = kind == .both || kind == .framesets

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        let dateRange: DateInterval? = {
            guard let fromStr = from, let toStr = to,
                  let fromDate = df.date(from: fromStr),
                  let toDate   = df.date(from: toStr) else { return nil }
            return DateInterval(start: fromDate, end: toDate)
        }()

        var frames: [ArchivedFrame] = []
        if showFrames {
            var query = FrameQuery()
            query.objectName  = object
            query.camera      = camera
            query.focalLength = focalLength
            query.limit       = limit
            if let t = type {
                query.frameTypes = t.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            if let f = filter {
                query.filters = f.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            query.processingLevel = level.flatMap { ProcessingLevel(rawValue: $0) }
            if stacked { query.stacked = true }
            query.dateRange = dateRange
            if let ra, let dec, let radius {
                query.coneSearch = FrameQuery.ConeSearch(ra: ra, dec: dec, radiusDeg: radius)
            }
            if rejectedOnly         { query.rejectionFilter = .onlyRejected }
            else if includeRejected { query.rejectionFilter = .includeAll }
            query.maxFWHM            = maxFwhm
            query.minStarCount       = minStars
            query.maxBackgroundNoise = maxBackgroundNoise
            query.maxEccentricity    = maxEccentricity
            frames = try await archive.frames(matching: query)
        }

        var frameSets: [ArchivedFrameSet] = []
        if showFrameSets {
            var query = FrameSetQuery()
            query.name       = name
            query.objectName = object
            query.camera     = camera
            if let t = type {
                query.frameTypes = t.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            if let f = filter {
                query.filters = f.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            query.processingLevel = level.flatMap { ProcessingLevel(rawValue: $0) }
            query.dateRange = dateRange
            frameSets = try await archive.frameSets(matching: query)
        }

        if json {
            printJSON(frames: frames, frameSets: frameSets)
        } else {
            printTable(frames: frames, frameSets: frameSets)
        }
    }

    private func printTable(frames: [ArchivedFrame], frameSets: [ArchivedFrameSet]) {
        let showFrames    = kind == .both || kind == .frames
        let showFrameSets = kind == .both || kind == .framesets
        var printed = false

        if showFrames {
            if frames.isEmpty {
                print("Frames: none found.")
            } else {
                print("Frames (\(frames.count)):\n")
                let hasQuality = frames.contains { $0.starCount != nil || $0.medianFWHM != nil }
                if hasQuality {
                    var table = TextTable(columns: [
                        .init("ID"), .init("Object"), .init("Type"), .init("Level"), .init("Filter"),
                        .init("Exposure", .right), .init("Stars", .right), .init("FWHM", .right),
                        .init("Ecc", .right), .init("Rej"), .init("File"),
                    ])
                    for f in frames {
                        let obj   = f.objectName ?? "-"
                        let filt  = f.filter ?? "-"
                        let exp   = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                        let stars = f.starCount.map { "\($0)" } ?? "-"
                        let fwhm: String
                        if let px = f.medianFWHM {
                            fwhm = f.medianFWHMArcsec.map { String(format: "%.2fpx/%.2f\"", px, $0) }
                                ?? String(format: "%.2fpx", px)
                        } else { fwhm = "-" }
                        let ecc  = f.medianEccentricity.map { String(format: "%.3f", $0) } ?? "-"
                        let rej  = f.rejected ? "✗" : ""
                        let file = f.filePath
                        table.addRow([f.id.uuidString, obj, f.frameType, f.processingLevel.rawValue,
                                      filt, exp, stars, fwhm, ecc, rej, file])
                    }
                    print(table.render())
                } else {
                    var table = TextTable(columns: [
                        .init("ID"), .init("Object"), .init("Type"), .init("Level"), .init("Filter"),
                        .init("Exposure", .right), .init("Rej"), .init("File"),
                    ])
                    for f in frames {
                        let obj  = f.objectName ?? "-"
                        let filt = f.filter ?? "-"
                        let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                        let rej  = f.rejected ? "✗" : ""
                        let file = f.filePath
                        table.addRow([f.id.uuidString, obj, f.frameType, f.processingLevel.rawValue,
                                      filt, exp, rej, file])
                    }
                    print(table.render())
                }
            }
            printed = true
        }

        if showFrameSets {
            if printed { print("") }
            if frameSets.isEmpty {
                print("Frame Sets: none found.")
            } else {
                print("Frame Sets (\(frameSets.count)):\n")
                let hasQuality = frameSets.contains { $0.medianFWHM != nil || $0.medianStarCount != nil }
                if hasQuality {
                    var table = TextTable(columns: [
                        .init("ID"), .init("Count", .right), .init("Type"), .init("Level"),
                        .init("Filter"), .init("Stars", .right), .init("FWHM", .right),
                        .init("Ecc", .right), .init("Bg", .right), .init("Name"),
                    ])
                    for fs in frameSets {
                        let stars = fs.medianStarCount.map { String(format: "%.0f", $0) } ?? "-"
                        let fwhm: String
                        if let px = fs.medianFWHM {
                            fwhm = fs.medianFWHMArcsec.map { String(format: "%.2fpx/%.2f\"", px, $0) }
                                ?? String(format: "%.2fpx", px)
                        } else { fwhm = "-" }
                        let ecc = fs.medianEccentricity.map { String(format: "%.3f", $0) } ?? "-"
                        let bg: String
                        if let e = fs.medianBackgroundNoiseElectrons {
                            bg = String(format: "%.1fe⁻", e)
                        } else if let n = fs.medianBackgroundNoise {
                            bg = String(format: "%.1fADU", n)
                        } else { bg = "-" }
                        table.addRow([fs.id.uuidString, "\(fs.frameCount)", fs.frameType,
                                      fs.processingLevel.rawValue, fs.filter ?? "-",
                                      stars, fwhm, ecc, bg, fs.name])
                    }
                    print(table.render())
                } else {
                    var table = TextTable(columns: [
                        .init("ID"), .init("Count", .right), .init("Type"),
                        .init("Level"), .init("Filter"), .init("Name"),
                    ])
                    for fs in frameSets {
                        table.addRow([fs.id.uuidString, "\(fs.frameCount)", fs.frameType,
                                      fs.processingLevel.rawValue, fs.filter ?? "-", fs.name])
                    }
                    print(table.render())
                }
            }
        }
    }

    private func printJSON(frames: [ArchivedFrame], frameSets: [ArchivedFrameSet]) {
        let iso = ISO8601DateFormatter()
        var result: [String: Any] = [:]

        if kind == .both || kind == .frames {
            result["frames"] = frames.map { f -> [String: Any] in
                var d: [String: Any] = [
                    "id": f.id.uuidString,
                    "frame_type": f.frameType,
                    "file_path": f.filePath,
                    "processing_level": f.processingLevel.rawValue,
                ]
                if let v = f.objectName              { d["object_name"]                   = v }
                if let v = f.filter                  { d["filter"]                         = v }
                if let v = f.exposureTime            { d["exposure_time"]                  = v }
                if let v = f.timestamp               { d["timestamp"]                      = iso.string(from: v) }
                if let v = f.camera                  { d["camera"]                         = v }
                if let v = f.starCount               { d["star_count"]                     = v }
                if let v = f.medianFWHM              { d["median_fwhm"]                    = v }
                if let v = f.medianFWHMArcsec        { d["median_fwhm_arcsec"]             = v }
                if let v = f.medianEccentricity      { d["median_eccentricity"]            = v }
                if let v = f.backgroundNoise         { d["background_noise"]               = v }
                if let v = f.backgroundNoiseElectrons { d["background_noise_electrons"]    = v }
                if let v = f.saturatedStarCount      { d["saturated_star_count"]           = v }
                if let v = f.hotPixelCount           { d["hot_pixel_count"]                = v }
                return d
            }
        }

        if kind == .both || kind == .framesets {
            result["framesets"] = frameSets.map { fs -> [String: Any] in
                var d: [String: Any] = [
                    "id": fs.id.uuidString,
                    "name": fs.name,
                    "frame_type": fs.frameType,
                    "processing_level": fs.processingLevel.rawValue,
                    "frame_count": fs.frameCount,
                    "excluded_frame_count": fs.excludedFrameCount,
                    "created_at": iso.string(from: fs.createdAt),
                ]
                if let v = fs.objectName { d["object_name"] = v }
                if let v = fs.filter     { d["filter"]      = v }
                if let v = fs.camera     { d["camera"]      = v }
                if let v = fs.dateFrom   { d["date_from"]   = iso.string(from: v) }
                if let v = fs.dateTo     { d["date_to"]     = iso.string(from: v) }
                if let v = fs.medianStarCount               { d["median_star_count"]                 = v }
                if let v = fs.medianFWHM                    { d["median_fwhm"]                       = v }
                if let v = fs.medianFWHMArcsec              { d["median_fwhm_arcsec"]                = v }
                if let v = fs.medianEccentricity            { d["median_eccentricity"]               = v }
                if let v = fs.medianBackgroundNoise         { d["median_background_noise"]           = v }
                if let v = fs.medianBackgroundNoiseElectrons { d["median_background_noise_electrons"] = v }
                return d
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) { print(str) }
    }
}
