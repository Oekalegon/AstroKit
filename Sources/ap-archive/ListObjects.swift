import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct ListObjects: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-objects",
        abstract: "List all objects in the archive with frame counts."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        let objects = try await archive.listObjects()

        if json {
            let dicts = objects.map { ["name": $0.name, "count": $0.count] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if objects.isEmpty {
            print("No objects in archive.")
            return
        }

        print("Objects in archive (\(objects.count)):\n")
        let nameWidth = objects.map { $0.name.count }.max() ?? 10
        for (name, count) in objects {
            let padded = name.padding(toLength: max(nameWidth, 10), withPad: " ", startingAt: 0)
            print("  \(padded)  \(count) frame(s)")
        }
    }
}
