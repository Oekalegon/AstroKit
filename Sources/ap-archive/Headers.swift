import ArgumentParser
import AstrophotoArchiveKit
import AstrophotoKit
import Foundation

struct Headers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the FITS header of an archive frame, grouped with human readable names."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Frame UUID (from ap-archive search).")
    var id: String

    @Flag(name: .shortAndLong, help: "Output as JSON (includes the original header keywords and values).")
    var json = false

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("'\(id)' is not a valid UUID.")
        }
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        guard let frame = try await archive.frame(id: uuid) else {
            throw ValidationError("No frame with id \(id) found in the archive.")
        }
        guard FileManager.default.fileExists(atPath: frame.filePath) else {
            throw ValidationError("Archive frame file not found on disk: \(frame.filePath)")
        }

        let fitsFile = try FITSFile(path: frame.filePath)
        let metadata = try fitsFile.readHeader()

        if json {
            var object = FITSKeywordCatalog.jsonObject(from: metadata)
            object["frame_id"] = frame.id.uuidString
            object["file"] = frame.filePath
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            print(String(data: data, encoding: .utf8)!)
            return
        }

        print("Frame: \(frame.id.uuidString)")
        print("File:  \(frame.filePath)")
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
