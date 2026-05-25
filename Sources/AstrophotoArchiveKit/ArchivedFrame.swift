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
        sessionEnd: Date? = nil
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
    }
}
