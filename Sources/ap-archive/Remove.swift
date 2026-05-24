import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a frame from the archive by its ID."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Archive frame ID (UUID).")
    var id: String

    @Flag(name: .long, help: "Also delete the FITS file from disk.")
    var deleteFile: Bool = false

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("Invalid UUID: \(id)")
        }
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        try await archive.remove(id: uuid, deleteFile: deleteFile)
        print("Removed frame \(id) from archive.\(deleteFile ? " File deleted." : "")")
    }
}
