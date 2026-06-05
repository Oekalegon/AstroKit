import Foundation

public enum ArchiveError: Error, LocalizedError, Sendable {
    case missingEnvironment
    case databaseError(String)
    case fileNotFound(String)
    case frameSetError(String)

    public var errorDescription: String? {
        switch self {
        case .missingEnvironment:
            return "ASTROARCHIVE_PATH environment variable is not set"
        case .databaseError(let msg):
            return "Archive database error: \(msg)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .frameSetError(let msg):
            return "Frame set error: \(msg)"
        }
    }
}
