import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Reject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark a frame as rejected so it is excluded from processing."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Archive frame ID (UUID).")
    var id: String

    @Option(name: .long, help: "Reason for rejection.")
    var reason: String?

    @Flag(name: .long, help: "Remove the rejection flag (un-reject the frame).")
    var undo: Bool = false

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("Invalid UUID: \(id)")
        }
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        if undo {
            try await archive.unreject(id: uuid)
            print("Frame \(id) un-rejected.")
        } else {
            try await archive.reject(id: uuid, reason: reason)
            let suffix = reason.map { "  Reason: \($0)" } ?? ""
            print("Frame \(id) marked as rejected.\(suffix)")
        }
    }
}
