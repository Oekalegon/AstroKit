import Foundation

/// Describes what changed between two versions of a pipeline result frame.
///
/// Computed on demand by `Archive.diff(_:predecessor:)`. Nothing is stored in the
/// database — all information is derived from the two frames and their processing runs.
public struct FrameDiff: Sendable {

    // MARK: - Nested types

    /// A single pipeline parameter that changed value between two runs.
    public struct ParameterChange: Sendable {
        /// Parameter key.
        public let key: String
        /// Value in the older frame's run. `nil` means the parameter was absent.
        public let from: String?
        /// Value in the newer frame's run. `nil` means the parameter was removed.
        public let to: String?
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

// MARK: - Archive API

extension Archive {
    /// Computes the diff between two versions of a pipeline result frame.
    ///
    /// - Parameters:
    ///   - frame: The newer frame (superseding).
    ///   - predecessor: The older frame (superseded). Typically `frame.supersedesID`
    ///     resolved via `Archive.frame(id:)`, or the next element in `lineage(of:)`.
    /// - Returns: A `FrameDiff` describing parameter changes, quality changes,
    ///   and input set differences between the two frames.
    public func diff(_ frame: ArchivedFrame, predecessor: ArchivedFrame) async throws -> FrameDiff {
        let newRun  = try await processingRun(for: frame)
        let oldRun  = try await processingRun(for: predecessor)

        // Parameter diff.
        let newParams = newRun?.run.parameters ?? [:]
        let oldParams = oldRun?.run.parameters ?? [:]
        let allKeys   = Set(newParams.keys).union(oldParams.keys).sorted()
        var paramChanges: [FrameDiff.ParameterChange] = []
        for key in allKeys {
            let oldVal = oldParams[key]
            let newVal = newParams[key]
            if oldVal != newVal {
                paramChanges.append(.init(key: key, from: oldVal, to: newVal))
            }
        }

        // Input set diff.
        let newInputIDs = Set((newRun?.inputs ?? []).compactMap { $0.frameID })
        let oldInputIDs = Set((oldRun?.inputs ?? []).compactMap { $0.frameID })
        let added   = newInputIDs.subtracting(oldInputIDs).sorted { $0.uuidString < $1.uuidString }
        let removed = oldInputIDs.subtracting(newInputIDs).sorted { $0.uuidString < $1.uuidString }

        // Quality diff.
        let quality = FrameDiff.QualityDiff(
            fwhm:                     (predecessor.medianFWHM,                    frame.medianFWHM),
            starCount:                (predecessor.starCount,                      frame.starCount),
            eccentricity:             (predecessor.medianEccentricity,             frame.medianEccentricity),
            backgroundNoise:          (predecessor.backgroundNoise,                frame.backgroundNoise),
            backgroundNoiseElectrons: (predecessor.backgroundNoiseElectrons,       frame.backgroundNoiseElectrons)
        )

        return FrameDiff(
            from:             predecessor,
            to:               frame,
            parameterChanges: paramChanges,
            quality:          quality,
            inputsAdded:      added,
            inputsRemoved:    removed
        )
    }
}
