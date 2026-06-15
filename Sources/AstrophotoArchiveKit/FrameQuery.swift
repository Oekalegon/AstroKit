import Foundation

public enum RejectionFilter: String, Sendable, Codable {
    /// Return only non-rejected frames (default — safe for processing pipelines).
    case excludeRejected
    /// Return all frames regardless of rejection status.
    case includeAll
    /// Return only rejected frames.
    case onlyRejected
}

// PERSISTENCE CONTRACT: FrameQuery is stored as JSON in the `criteria` column of
// frame_sets (migration v27, via FrameSetCriteria). Any new stored property MUST be
// optional (or declare a default in init(from:)) so that existing persisted criteria
// keep decoding as "legacy" sets lose their add-validation silently.
// See FrameSetCriteriaRoundTripTests for a pinned snapshot that catches breaking changes.
public struct FrameQuery: Sendable, Codable {
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

    // MARK: - Quality filters (frames without quality data are excluded when any of these is set)

    /// Only include frames whose median FWHM is ≤ this value (pixels).
    public var maxFWHM: Double?
    /// Only include frames with at least this many detected stars.
    public var minStarCount: Int?
    /// Only include frames whose background noise is ≤ this value (normalised 0–1).
    public var maxBackgroundNoise: Double?
    /// Only include frames whose mean star eccentricity is ≤ this value (0=circular, 1=line).
    public var maxEccentricity: Double?

    public init() {}

    public struct ConeSearch: Sendable, Codable {
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
