import Foundation

public struct ArchiveConfiguration: Sendable {
    public var rootURL: URL
    public var databaseURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.databaseURL = rootURL.appendingPathComponent("archive.db")
    }

    public init(rootURL: URL, databaseURL: URL) {
        self.rootURL = rootURL
        self.databaseURL = databaseURL
    }

    /// Reads the archive root from the `ASTROARCHIVE_PATH` environment variable,
    /// falling back to `~/.config/astrophotokit/archive_path` if the variable is not set.
    public static func fromEnvironment() throws -> ArchiveConfiguration {
        if let path = ProcessInfo.processInfo.environment["ASTROARCHIVE_PATH"], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            return ArchiveConfiguration(rootURL: URL(fileURLWithPath: expanded))
        }
        // Fallback: read path from config file
        let configFile = ("~/.config/astrophotokit/archive_path" as NSString).expandingTildeInPath
        if let path = try? String(contentsOfFile: configFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            return ArchiveConfiguration(rootURL: URL(fileURLWithPath: expanded))
        }
        throw ArchiveError.missingEnvironment
    }
}
