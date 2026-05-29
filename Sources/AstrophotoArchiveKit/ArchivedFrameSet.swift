import Foundation

/// A named, homogeneous collection of archived frames.
///
/// All members share the same `frameType` and `processingLevel`.
/// The `filter` field holds a single filter name when all frames agree,
/// or a comma-separated list when the set was created with `--force` to
/// override the mixed-filter restriction.
/// All other shared properties are nil when member frames disagree.
public struct ArchivedFrameSet: Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var frameType: String
    public var processingLevel: ProcessingLevel
    public var createdAt: Date
    /// Total number of member frames, including excluded ones.
    public var frameCount: Int
    /// Number of members with the excluded flag set.
    public var excludedFrameCount: Int

    // Shared scalar properties — nil when member frames disagree.
    public var objectName: String?
    /// Single filter name, or comma-separated list when created with --force.
    public var filter: String?
    public var camera: String?
    public var exposureTime: Double?
    public var gain: Double?
    public var offset: Double?
    public var width: Int?
    public var height: Int?
    public var pixelScale: Double?
    public var focalLength: Double?
    public var positionAngle: Double?

    // Date span across all member frames.
    public var dateFrom: Date?
    public var dateTo: Date?

    // Temperature statistics across member frames that carry a temperature reading.
    public var temperatureMean: Double?
    public var temperatureMin: Double?
    public var temperatureMax: Double?

    public init(
        id: UUID, name: String, frameType: String, processingLevel: ProcessingLevel,
        createdAt: Date, frameCount: Int, excludedFrameCount: Int = 0,
        objectName: String?, filter: String?, camera: String?,
        exposureTime: Double?, gain: Double?, offset: Double?,
        width: Int?, height: Int?,
        pixelScale: Double?, focalLength: Double?, positionAngle: Double?,
        dateFrom: Date?, dateTo: Date?,
        temperatureMean: Double?, temperatureMin: Double?, temperatureMax: Double?
    ) {
        self.id = id
        self.name = name
        self.frameType = frameType
        self.processingLevel = processingLevel
        self.createdAt = createdAt
        self.frameCount = frameCount
        self.excludedFrameCount = excludedFrameCount
        self.objectName = objectName
        self.filter = filter
        self.camera = camera
        self.exposureTime = exposureTime
        self.gain = gain
        self.offset = offset
        self.width = width
        self.height = height
        self.pixelScale = pixelScale
        self.focalLength = focalLength
        self.positionAngle = positionAngle
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.temperatureMean = temperatureMean
        self.temperatureMin = temperatureMin
        self.temperatureMax = temperatureMax
    }
}
