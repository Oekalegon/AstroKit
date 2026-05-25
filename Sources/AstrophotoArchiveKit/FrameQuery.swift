import Foundation

public enum RejectionFilter: Sendable {
    /// Return only non-rejected frames (default — safe for processing pipelines).
    case excludeRejected
    /// Return all frames regardless of rejection status.
    case includeAll
    /// Return only rejected frames.
    case onlyRejected
}

public struct FrameQuery: Sendable {
    public var objectName: String?
    public var camera: String?
    public var coneSearch: ConeSearch?
    public var frameTypes: [String]?
    public var filters: [String]?
    public var dateRange: DateInterval?
    public var temperatureRange: ClosedRange<Double>?
    public var calibrated: Bool?
    public var stacked: Bool?
    public var stretched: Bool?
    public var processingLevel: ProcessingLevel?
    public var rejectionFilter: RejectionFilter = .excludeRejected
    public var limit: Int?

    public init() {}

    public struct ConeSearch: Sendable {
        public var ra: Double           // degrees
        public var dec: Double          // degrees
        public var radiusDeg: Double

        public init(ra: Double, dec: Double, radiusDeg: Double) {
            self.ra = ra
            self.dec = dec
            self.radiusDeg = radiusDeg
        }
    }
}
