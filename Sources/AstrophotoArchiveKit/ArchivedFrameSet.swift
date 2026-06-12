import Foundation

/// The selection criteria a frame set was created with.
///
/// Persisted alongside the set so that frames added later can be validated
/// against the same query (and quality thresholds) used at creation time.
public struct FrameSetCriteria: Sendable, Codable {
    /// The frame query used to select the original members. Stored with
    /// `maxFWHM`/`maxEccentricity` stripped — those live in the threshold
    /// fields below because they mark frames excluded rather than filter them out.
    public var query: FrameQuery
    /// Frames whose median FWHM (pixels) exceeds this are added but marked excluded.
    public var maxFWHM: Double?
    /// Frames whose median eccentricity exceeds this are added but marked excluded.
    public var maxEccentricity: Double?

    public init(query: FrameQuery, maxFWHM: Double? = nil, maxEccentricity: Double? = nil) {
        self.query = query
        self.maxFWHM = maxFWHM
        self.maxEccentricity = maxEccentricity
    }
}

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
    public var telescope: String?
    public var site: String?
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

    // Quality aggregates — medians over active (non-excluded) member frames.
    // Populated on creation and refreshed by `ap-archive frameset quality`.
    public var medianStarCount: Double?
    public var medianFWHM: Double?
    /// Derived from `medianFWHM × pixelScale`. Only available when both are known.
    public var medianFWHMArcsec: Double? { medianFWHM.flatMap { fwhm in pixelScale.map { fwhm * $0 } } }
    public var medianEccentricity: Double?
    public var medianBackgroundNoise: Double?
    public var medianBackgroundNoiseElectrons: Double?

    /// The selection criteria the set was created with. Nil for sets created
    /// before criteria were persisted (schema < v27).
    public var criteria: FrameSetCriteria?

    public init(
        id: UUID, name: String, frameType: String, processingLevel: ProcessingLevel,
        createdAt: Date, frameCount: Int, excludedFrameCount: Int = 0,
        objectName: String?, filter: String?, camera: String?,
        telescope: String? = nil, site: String? = nil,
        exposureTime: Double?, gain: Double?, offset: Double?,
        width: Int?, height: Int?,
        pixelScale: Double?, focalLength: Double?, positionAngle: Double?,
        dateFrom: Date?, dateTo: Date?,
        temperatureMean: Double?, temperatureMin: Double?, temperatureMax: Double?,
        medianStarCount: Double? = nil, medianFWHM: Double? = nil,
        medianEccentricity: Double? = nil, medianBackgroundNoise: Double? = nil,
        medianBackgroundNoiseElectrons: Double? = nil,
        criteria: FrameSetCriteria? = nil
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
        self.telescope = telescope
        self.site = site
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
        self.medianStarCount = medianStarCount
        self.medianFWHM = medianFWHM
        self.medianEccentricity = medianEccentricity
        self.medianBackgroundNoise = medianBackgroundNoise
        self.medianBackgroundNoiseElectrons = medianBackgroundNoiseElectrons
        self.criteria = criteria
    }
}

/// Outcome of `Archive.addFrames(toFrameSet:frameIDs:force:)`.
public struct FrameSetAddResult: Sendable {
    /// The frame set after the addition, with refreshed aggregates.
    public let frameSet: ArchivedFrameSet
    /// Frames that were added, in input order.
    public let addedIDs: [UUID]
    /// Frames skipped because they were already members of the set.
    public let alreadyMemberIDs: [UUID]
    /// Subset of `addedIDs` that was added but marked excluded because a quality
    /// threshold from the set's creation criteria was exceeded, with the reason.
    public let excludedReasons: [UUID: String]
}

/// Outcome of `Archive.removeFrames(fromFrameSet:frameIDs:)`.
public struct FrameSetRemoveResult: Sendable {
    /// The frame set after the removal, with refreshed aggregates.
    public let frameSet: ArchivedFrameSet
    /// Frames that were removed, in input order.
    public let removedIDs: [UUID]
    /// Frames skipped because they were not members of the set.
    public let notMemberIDs: [UUID]
}
