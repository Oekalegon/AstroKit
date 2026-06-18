import AstrophotoArchiveKit
import AstrophotoToolDefinitions
import AstrophotoToolsKit
import Foundation

struct ArchiveTools {

    static let definitions: [[String: Any]] = ArchiveToolHandler.definitions

    func call(name: String, arguments: [String: Any]) async throws -> String {
        let archive = try makeArchive()
        return try await ArchiveToolHandler(archive: archive).call(name: name, arguments: arguments)
    }

    private func makeArchive() throws -> Archive {
        let config = try ArchiveConfiguration.fromEnvironment()
        return try Archive(configuration: config)
    }
}
