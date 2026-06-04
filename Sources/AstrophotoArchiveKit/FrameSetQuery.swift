import Foundation

public struct FrameSetQuery: Sendable {
    /// Partial match on frameset name.
    public var name: String?
    /// Partial match on object name.
    public var objectName: String?
    public var frameTypes: [String]?
    public var filters: [String]?
    public var processingLevel: ProcessingLevel?
    public var camera: String?
    /// Matches framesets whose date span overlaps this interval.
    public var dateRange: DateInterval?

    public init() {}
}
