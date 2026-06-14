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

        // Parameter diff — typed so "3.0" == "3", "true" == "true", etc.
        let newParams = newRun?.run.parameters ?? [:]
        let oldParams = oldRun?.run.parameters ?? [:]
        let allKeys   = Set(newParams.keys).union(oldParams.keys).sorted()
        var paramChanges: [FrameDiff.ParameterChange] = []
        for key in allKeys {
            let oldVal = oldParams[key].map { FrameDiff.ParameterValue($0) }
            let newVal = newParams[key].map { FrameDiff.ParameterValue($0) }
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
            fwhm:                     (predecessor.medianFWHM,              frame.medianFWHM),
            starCount:                (predecessor.starCount,                frame.starCount),
            eccentricity:             (predecessor.medianEccentricity,       frame.medianEccentricity),
            backgroundNoise:          (predecessor.backgroundNoise,          frame.backgroundNoise),
            backgroundNoiseElectrons: (predecessor.backgroundNoiseElectrons, frame.backgroundNoiseElectrons)
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
