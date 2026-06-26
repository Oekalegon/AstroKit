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
    public var telescope: String?
    public var site: String?
    public var focalLength: Double?
    /// Only include frames whose focal length is within this range (mm).
    public var focalLengthRange: ClosedRange<Double>?
    /// Only include frames whose aperture is within this range (mm).
    public var apertureRange: ClosedRange<Double>?
    /// Only include frames whose physical pixel size is within this range (µm, unbinned).
    public var pixelSizeRange: ClosedRange<Double>?
    /// Exact match on binning factor (FITS `XBINNING`).
    public var binning: Int?
    /// Exact match on camera gain setting (FITS `GAIN` keyword).
    public var gain: Double?
    /// Exact match on camera offset/pedestal setting (FITS `OFFSET`/`PEDESTAL` keyword).
    public var offset: Double?
    /// Only include frames whose exposure time is within this range (seconds).
    public var exposureTimeRange: ClosedRange<Double>?
    /// When true, include only master calibration frames (ISMASTER=T in FITS header).
    /// When false, exclude master frames. When nil, no filter is applied.
    public var isMaster: Bool?
    public var sessionID: UUID?
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

    // MARK: - Optics / sensor

    /// Only include frames whose pixel scale is within this range (arcsec/px).
    public var pixelScaleRange: ClosedRange<Double>?
    /// Only include frames whose image width is within this range (pixels).
    public var widthRange: ClosedRange<Int>?
    /// Only include frames whose image height is within this range (pixels).
    public var heightRange: ClosedRange<Int>?
    /// Exact match on bit depth (FITS `BITPIX`, e.g. 16, 32, -32).
    public var bitpix: Int?
    /// Only include frames whose electron conversion factor is within this range (e⁻/ADU).
    public var egainRange: ClosedRange<Double>?
    /// Only include frames whose position angle is within this range (degrees east of north).
    public var positionAngleRange: ClosedRange<Double>?

    // MARK: - Archive timestamps

    /// Only include frames added to the archive on or after this date.
    public var addedAfter: Date?
    /// Only include frames added to the archive on or before this date.
    public var addedBefore: Date?

    // MARK: - Quality filters (frames without quality data are excluded when any of these is set)

    /// Only include frames whose median FWHM is ≤ this value (pixels).
    public var maxFWHM: Double?
    /// Only include frames with at least this many detected stars.
    public var minStarCount: Int?
    /// Only include frames whose background noise is ≤ this value (normalised 0–1).
    public var maxBackgroundNoise: Double?
    /// Only include frames whose mean star eccentricity is ≤ this value (0=circular, 1=line).
    public var maxEccentricity: Double?
    /// Only include frames with at most this many saturated stars.
    public var maxSaturatedStarCount: Int?
    /// Only include frames with at most this many hot pixels (calibration frames).
    public var maxHotPixelCount: Int?

    // MARK: - Celestial context filters

    /// Only include frames where the Sun was at or below this altitude in degrees at capture time.
    /// Use -18 for astronomical night, -12 for nautical twilight, -6 for civil twilight.
    public var maxSunAltitude: Double?
    /// Only include frames where the Moon was at least this many degrees from the target field.
    public var minMoonSeparation: Double?
    /// Only include frames where the Moon illumination was at most this fraction (0–1).
    public var maxMoonIllumination: Double?

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
