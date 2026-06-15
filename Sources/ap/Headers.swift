import ArgumentParser
import AstrophotoKit
import Foundation

extension AP {
    struct Headers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "headers",
            abstract: "Print the FITS header of a file, grouped with human readable names."
        )

        @Argument(help: "Path to a FITS file.")
        var path: String

        @Flag(name: .shortAndLong, help: "Output as JSON (includes the original header keywords and values).")
        var json = false

        func run() async throws {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ValidationError("File not found: \(path)")
            }
            let fitsFile = try FITSFile(path: expanded)
            let metadata = try fitsFile.readHeader()

            if json {
                var object = FITSKeywordCatalog.jsonObject(from: metadata)
                object["file"] = expanded
                let data = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(data: data, encoding: .utf8)!)
                return
            }

            print("File: \(expanded)")
            for section in FITSKeywordCatalog.groupedSections(from: metadata) {
                print("\n\(section.group.rawValue)")
                print(String(repeating: "─", count: section.group.rawValue.count + 4))
                let nameWidth = section.entries.map { $0.displayName.count }.max() ?? 0
                for entry in section.entries {
                    let name = entry.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    print("  \(name)  \(entry.displayValue)  [\(entry.keyword)]")
                }
            }
        }
    }
}
