import Foundation

public struct ArchivedTable: Sendable, Identifiable {
    public let id: UUID
    public var filePath: String
    public var hduIndex: Int
    public var tableName: String?
    public var frameID: UUID?
    public var addedAt: Date
}
