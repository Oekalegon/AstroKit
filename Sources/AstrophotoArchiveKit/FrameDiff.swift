import Foundation

/// Describes what changed between two versions of a pipeline result frame.
///
/// Computed on demand by `Archive.diff(_:predecessor:)`. Nothing is stored in the
/// database — all information is derived from the two frames and their processing runs.
public struct FrameDiff: Sendable {

    /// A single pipeline parameter that changed value between two runs.
    public struct ParameterChange: Sendable {
        /// Parameter key.
        public let key: String
        /// Typed value in the older frame's run. `nil` means the parameter was absent.
        public let from: ParameterValue?
        /// Typed value in the newer frame's run. `nil` means the parameter was removed.
        public let to: ParameterValue?
    }

    /// Changes to quality metrics between two frames.
    public struct QualityDiff: Sendable {
        public let fwhm:                    (from: Double?, to: Double?)
        public let starCount:               (from: Int?,    to: Int?)
        public let eccentricity:            (from: Double?, to: Double?)
        public let backgroundNoise:         (from: Double?, to: Double?)
        public let backgroundNoiseElectrons:(from: Double?, to: Double?)

        var hasAnyValue: Bool {
            fwhm.from != nil || fwhm.to != nil ||
            starCount.from != nil || starCount.to != nil ||
            eccentricity.from != nil || eccentricity.to != nil ||
            backgroundNoise.from != nil || backgroundNoise.to != nil ||
            backgroundNoiseElectrons.from != nil || backgroundNoiseElectrons.to != nil
        }
    }

    // MARK: - Properties

    /// The older frame (predecessor).
    public let from: ArchivedFrame
    /// The newer frame (the one that supersedes `from`).
    public let to: ArchivedFrame

    /// Pipeline parameters that changed, were added, or were removed between the two runs.
    /// Empty when both frames have no run, or when the parameters are identical.
    public let parameterChanges: [ParameterChange]

    /// Quality metric changes. Fields are `(nil, nil)` when a metric is absent in both frames.
    public let quality: QualityDiff

    /// Input frame archive IDs present in `to`'s run but not in `from`'s run.
    public let inputsAdded: [UUID]

    /// Input frame archive IDs present in `from`'s run but not in `to`'s run.
    public let inputsRemoved: [UUID]
}
