import Foundation

public struct ArchivedFrame: Sendable, Identifiable {
    public let id: UUID
    /// Absolute path to the FITS file on disk.
    public var filePath: String
    public var objectName: String?
    public var ra: Double?              // degrees
    public var dec: Double?             // degrees
    public var healpixPixel: Int64?     // HEALPix nside=64 ring-scheme pixel index
    public var frameType: String
    public var filter: String?
    public var camera: String?
    public var focalLength: Double?     // mm
    public var pixelScale: Double?      // arcsec/pixel
    public var temperature: Double?     // sensor °C
    public var timestamp: Date?
    public var exposureTime: Double?    // seconds
    public var gain: Double?
    public var offset: Double?
    public var width: Int?
    public var height: Int?
    public var bitpix: Int?
    public var calibrated: Bool
    public var stacked: Bool
    public var stretched: Bool
    public var processingLevel: ProcessingLevel
    public var addedAt: Date
    /// JPEG or PNG thumbnail stored as raw bytes. Nil until autostretch is available.
    public var thumbnail: Data?
    /// True if the frame has been flagged as unusable and should be excluded from processing.
    public var rejected: Bool
    public var rejectedReason: String?
    /// Camera rotation in degrees east of north (POSANGLE / PA / ROTATANG FITS keyword).
    public var positionAngle: Double?
    /// ID of the processing run that produced this frame, if it was the output of a pipeline.
    public var processingRunID: UUID?
    /// Earliest input-frame timestamp for stacked frames (DATE-BEG).
    public var sessionBeg: Date?
    /// Latest input-frame timestamp for stacked frames (DATE-END).
    public var sessionEnd: Date?
    /// Minimum CCD temperature across input frames (stacked frames only).
    public var temperatureMin: Double?
    /// Maximum CCD temperature across input frames (stacked frames only).
    public var temperatureMax: Double?
    /// File creation date used for archive deduplication (DATE header → DATE-OBS → filesystem).
    public var fileDate: Date?

    // MARK: - Quality metrics (populated by analysis pipelines or read from FITS headers)

    /// Number of stars detected in this frame (populated by frame_quality / star_detection / optical_quality pipeline).
    public var starCount: Int?
    /// Median FWHM in pixels, averaged over major and minor axes (populated by frame_quality / star_detection pipeline).
    public var medianFWHM: Double?
    /// Background level in ADU for light frames; noise sigma in ADU for calibration frames.
    /// Populated by frame_quality / calibration_quality pipeline or read from FITS header BACKNOIS.
    /// Note: frames analysed with older pipelines (star_detection, optical_quality) store a normalised
    /// 0–1 value here; frames analysed with frame_quality or calibration_quality store ADU.
    public var backgroundNoise: Double?
    /// Median star eccentricity (0 = circular, 1 = line; populated by frame_quality / star_detection
    /// / frame_registration pipeline or read from FITS header MEDECCEN).
    public var medianEccentricity: Double?
    /// Number of saturated stars (peak pixel ≥ 90 % full-scale).
    /// Populated by frame_quality pipeline or read from FITS header NSATSTAR.
    public var saturatedStarCount: Int?
    /// Approximate count of hot pixels (value > mean + N·sigma).
    /// Populated by calibration_quality pipeline or read from FITS header NHOTPIX.
    public var hotPixelCount: Int?

    public init(
        id: UUID, filePath: String, objectName: String?, ra: Double?, dec: Double?,
        healpixPixel: Int64?, frameType: String, filter: String?, camera: String?,
        focalLength: Double?, pixelScale: Double?, temperature: Double?, timestamp: Date?,
        exposureTime: Double?, gain: Double?, offset: Double?,
        width: Int?, height: Int?, bitpix: Int?,
        calibrated: Bool, stacked: Bool, stretched: Bool,
        processingLevel: ProcessingLevel, addedAt: Date,
        thumbnail: Data? = nil,
        rejected: Bool = false, rejectedReason: String? = nil,
        positionAngle: Double? = nil,
        processingRunID: UUID? = nil,
        sessionBeg: Date? = nil,
        sessionEnd: Date? = nil,
        temperatureMin: Double? = nil,
        temperatureMax: Double? = nil,
        fileDate: Date? = nil,
        starCount: Int? = nil,
        medianFWHM: Double? = nil,
        backgroundNoise: Double? = nil,
        medianEccentricity: Double? = nil,
        saturatedStarCount: Int? = nil,
        hotPixelCount: Int? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.objectName = objectName
        self.ra = ra
        self.dec = dec
        self.healpixPixel = healpixPixel
        self.frameType = frameType
        self.filter = filter
        self.camera = camera
        self.focalLength = focalLength
        self.pixelScale = pixelScale
        self.temperature = temperature
        self.timestamp = timestamp
        self.exposureTime = exposureTime
        self.gain = gain
        self.offset = offset
        self.width = width
        self.height = height
        self.bitpix = bitpix
        self.calibrated = calibrated
        self.stacked = stacked
        self.stretched = stretched
        self.processingLevel = processingLevel
        self.addedAt = addedAt
        self.thumbnail = thumbnail
        self.rejected = rejected
        self.rejectedReason = rejectedReason
        self.positionAngle = positionAngle
        self.processingRunID = processingRunID
        self.sessionBeg = sessionBeg
        self.sessionEnd = sessionEnd
        self.temperatureMin = temperatureMin
        self.temperatureMax = temperatureMax
        self.fileDate = fileDate
        self.starCount = starCount
        self.medianFWHM = medianFWHM
        self.backgroundNoise = backgroundNoise
        self.medianEccentricity = medianEccentricity
        self.saturatedStarCount = saturatedStarCount
        self.hotPixelCount = hotPixelCount
    }
}
