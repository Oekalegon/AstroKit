import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Calibration: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List calibration frames (bias, dark, flat, darkFlat) grouped by type."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Option(name: .long, help: "Scope: all (default), source (raw frames only), masters (master stacks only), framesets (calibration frame sets only).")
    var scope: String = "all"

    @Option(name: .long, help: "Calibration type: bias, dark, flat, darkFlat. Omit to show all types.")
    var type: String?

    @Option(name: .long, help: "Centre CCD temperature in °C — returns frames within ±temp-tolerance of this value.")
    var tempCenter: Double?

    @Option(name: .long, help: "Temperature tolerance ±°C around --temp-center (default 2.0).")
    var tempTolerance: Double = 2.0

    @Option(name: .long, help: "Start date YYYY-MM-DD (inclusive).")
    var from: String?

    @Option(name: .long, help: "End date YYYY-MM-DD (inclusive).")
    var to: String?

    @Option(name: .long, help: "Camera name (exact match).")
    var camera: String?

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        let calibType = type.flatMap { CalibrationType(rawValue: $0) }
        if let rawType = type, calibType == nil {
            throw ValidationError("Unknown calibration type '\(rawType)'. Valid values: bias, dark, flat, darkFlat.")
        }

        let tempRange: ClosedRange<Double>? = tempCenter.map { ($0 - tempTolerance)...($0 + tempTolerance) }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone   = TimeZone(identifier: "UTC")
        let dateRange: DateInterval?
        if let fromStr = from, let toStr = to {
            guard let fromDate = df.date(from: fromStr), let toDate = df.date(from: toStr) else {
                throw ValidationError("Dates must be in YYYY-MM-DD format.")
            }
            dateRange = DateInterval(start: fromDate, end: toDate.addingTimeInterval(86399))
        } else {
            dateRange = nil
        }

        if scope == "framesets" {
            let sets = try await archive.calibrationFrameSets(type: calibType)
            printFrameSets(sets)
            return
        }

        let calScope: CalibrationScope
        switch scope {
        case "source":  calScope = .source
        case "masters": calScope = .masters
        case "all":     calScope = .all
        default:        throw ValidationError("Unknown scope '\(scope)'. Valid values: all, source, masters, framesets.")
        }

        let frames = try await archive.calibrationFrames(
            scope: calScope,
            type: calibType,
            temperatureRange: tempRange,
            dateRange: dateRange,
            camera: camera
        )
        printFrames(frames)
    }

    // MARK: - Output

    private func printFrames(_ frames: [ArchivedFrame]) {
        if frames.isEmpty {
            print("No calibration frames found.")
            return
        }

        let grouped   = Dictionary(grouping: frames, by: { $0.frameType })
        let typeOrder = ["bias", "masterBias", "dark", "masterDark", "darkFlat", "masterDarkFlat", "flat", "masterFlat"]
        let iso       = ISO8601DateFormatter()
        func shortDate(_ d: Date) -> String {
            String(iso.string(from: d).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }

        print("Calibration Frames (\(frames.count) total)\n")
        for type_ in typeOrder {
            guard let group = grouped[type_], !group.isEmpty else { continue }
            print("\(typeLabel(type_))  —  \(group.count) frame(s)")
            var table = TextTable(columns: [
                .init("ID"),
                .init("Temp", .right),
                .init("Exp", .right),
                .init("Filter"),
                .init("Date"),
                .init("File"),
            ])
            for f in group {
                let temp   = f.temperature.map { String(format: "%.1f°C", $0) } ?? "-"
                let exp    = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                let filter = f.filter ?? "-"
                let date   = f.timestamp.map { shortDate($0) } ?? "-"
                let file   = (f.filePath as NSString).lastPathComponent
                table.addRow([f.id.uuidString, temp, exp, filter, date, file])
            }
            print(table.render())
        }
    }

    private func printFrameSets(_ sets: [ArchivedFrameSet]) {
        if sets.isEmpty {
            print("No calibration frame sets found.")
            return
        }

        let iso = ISO8601DateFormatter()
        print("Calibration Frame Sets (\(sets.count))\n")
        var table = TextTable(columns: [
            .init("ID"),
            .init("Type"),
            .init("Name"),
            .init("Frames", .right),
            .init("Temp", .right),
            .init("Exp", .right),
            .init("Date span"),
            .init("Camera"),
        ])
        for fs in sets {
            let temp: String
            if let mn = fs.temperatureMin, let mx = fs.temperatureMax {
                temp = abs(mx - mn) < 0.5
                    ? String(format: "%.1f°C", (mn + mx) / 2)
                    : String(format: "%.1f–%.1f°C", mn, mx)
            } else { temp = "-" }
            let exp    = fs.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
            let dates: String
            if let from = fs.dateFrom, let to = fs.dateTo {
                let f = String(iso.string(from: from).prefix(10))
                let t = String(iso.string(from: to).prefix(10))
                dates = f == t ? f : "\(f) – \(t)"
            } else { dates = "-" }
            let cam = fs.camera ?? "-"
            table.addRow([fs.id.uuidString, fs.frameType, fs.name, "\(fs.frameCount)", temp, exp, dates, cam])
        }
        print(table.render())
    }

    private func typeLabel(_ type_: String) -> String {
        switch type_ {
        case "bias":           return "Bias"
        case "masterBias":     return "Master Bias"
        case "dark":           return "Dark"
        case "masterDark":     return "Master Dark"
        case "darkFlat":       return "Dark Flat"
        case "masterDarkFlat": return "Master Dark Flat"
        case "flat":           return "Flat"
        case "masterFlat":     return "Master Flat"
        default:               return type_
        }
    }
}
