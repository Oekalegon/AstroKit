import Foundation

public enum RejectionFilter: Sendable {
    /// Return only non-rejected frames (default — safe for processing pipelines).
    case excludeRejected
    /// Return all frames regardless of rejection status.
    case includeAll
    /// Return only rejected frames.
    case onlyRejected
}

/// Controls which calibration frames are returned by a calibration query.
public enum CalibrationScope: Sendable {
    /// All calibration frames — both raw source frames and master stacks.
    case all
    /// Raw (uncombined) source calibration frames only: bias, dark, flat, darkFlat.
    case source
    /// Master calibration stacks only: masterBias, masterDark, masterFlat, masterDarkFlat.
    case masters
}

/// A calibration frame type, independent of whether it is a source or master frame.
public enum CalibrationType: String, CaseIterable, Sendable {
    case bias    = "bias"
    case dark    = "dark"
    case flat    = "flat"
    case darkFlat = "darkFlat"

    /// The archive `frame_type` string for a raw source frame of this type.
    public var sourceFrameType: String { rawValue }

    /// The archive `frame_type` string for a master calibration stack of this type.
    public var masterFrameType: String {
        switch self {
        case .bias:    return "masterBias"
        case .dark:    return "masterDark"
        case .flat:    return "masterFlat"
        case .darkFlat: return "masterDarkFlat"
        }
    }

    /// Both frame type strings (source and master) for this calibration type.
    public var allFrameTypes: [String] { [sourceFrameType, masterFrameType] }
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

    // MARK: - Calibration factory

    /// Builds a query that returns calibration frames for the given scope and optional type.
    ///
    /// - Parameters:
    ///   - scope: Whether to return source frames, master stacks, or both.
    ///   - type: Optional restriction to one calibration type. `nil` returns all calibration types.
    ///   - temperatureRange: Optional CCD temperature filter (°C). Useful for selecting darks.
    ///   - dateRange: Optional timestamp filter. Useful for selecting flats by session date.
    ///   - camera: Optional camera name (exact match).
    public static func forCalibration(
        scope: CalibrationScope = .all,
        type: CalibrationType? = nil,
        temperatureRange: ClosedRange<Double>? = nil,
        dateRange: DateInterval? = nil,
        camera: String? = nil
    ) -> FrameQuery {
        let baseTypes = type.map { [$0] } ?? CalibrationType.allCases
        let frameTypes: [String]
        switch scope {
        case .source:  frameTypes = baseTypes.map { $0.sourceFrameType }
        case .masters: frameTypes = baseTypes.map { $0.masterFrameType }
        case .all:     frameTypes = baseTypes.flatMap { $0.allFrameTypes }
        }
        var q = FrameQuery()
        q.frameTypes        = frameTypes
        q.camera            = camera
        q.temperatureRange  = temperatureRange
        q.dateRange         = dateRange
        return q
    }

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
