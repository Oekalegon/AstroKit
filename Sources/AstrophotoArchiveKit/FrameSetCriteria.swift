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
