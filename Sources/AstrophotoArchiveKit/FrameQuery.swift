import Foundation

public struct FrameQuery: Sendable {
    public var objectName: String?
    public var coneSearch: ConeSearch?
    public var frameTypes: [String]?
    public var filters: [String]?
    public var dateRange: DateInterval?
    public var temperatureRange: ClosedRange<Double>?
    public var calibrated: Bool?
    public var stacked: Bool?
    public var stretched: Bool?
    public var processingLevel: ProcessingLevel?
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
