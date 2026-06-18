import Foundation

public struct ToolError: Error, LocalizedError {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
