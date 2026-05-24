import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show archive statistics."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        let stats   = try await archive.statistics()

        if json {
            printJSON(stats)
            return
        }

        print("Archive Statistics")
        print("  Archive path: \(config.rootURL.path)")
        print("")
        print("  Total objects: \(stats.objectCount)")
        print("  Total frames:  \(stats.frameCount)")

        if !stats.frameCountByType.isEmpty {
            print("")
            print("  Frames by type:")
            for (type_, count) in stats.frameCountByType.sorted(by: { $0.key < $1.key }) {
                print("    \(type_.padding(toLength: 12, withPad: " ", startingAt: 0))  \(count)")
                if let byFilter = stats.frameCountByTypeAndFilter[type_], !byFilter.isEmpty {
                    for (filter, fCount) in byFilter.sorted(by: { $0.key < $1.key }) {
                        print("      \(filter.padding(toLength: 10, withPad: " ", startingAt: 0))  \(fCount)")
                    }
                }
            }
        }

        if !stats.processedFramesByObject.isEmpty {
            print("")
            print("  Processed frames by object:")
            for (obj, count) in stats.processedFramesByObject.sorted(by: { $0.key < $1.key }) {
                print("    \(obj): \(count)")
            }
        }

        print("")
        print("  Disk used:      \(stats.usedBytesFormatted)")
        print("  Disk available: \(stats.availableBytesFormatted)")
    }

    private func printJSON(_ stats: ArchiveStatistics) {
        let dict: [String: Any] = [
            "object_count":              stats.objectCount,
            "frame_count":               stats.frameCount,
            "frame_count_by_type":       stats.frameCountByType,
            "frame_count_by_type_filter": stats.frameCountByTypeAndFilter,
            "processed_by_object":       stats.processedFramesByObject,
            "used_bytes":                stats.usedBytes,
            "available_bytes":           stats.availableBytes,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
