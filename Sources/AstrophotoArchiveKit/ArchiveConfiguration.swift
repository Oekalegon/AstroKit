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

    /// Reads the archive root from the `ASTROARCHIVE_PATH` environment variable.
    public static func fromEnvironment() throws -> ArchiveConfiguration {
        guard let path = ProcessInfo.processInfo.environment["ASTROARCHIVE_PATH"] else {
            throw ArchiveError.missingEnvironment
        }
        let expanded = (path as NSString).expandingTildeInPath
        return ArchiveConfiguration(rootURL: URL(fileURLWithPath: expanded))
    }
}
