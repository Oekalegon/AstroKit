import AstrophotoKit
import Foundation
import HEALPixKit

/// The main archive actor. Thread-safe; all operations are async.
public actor Archive {
    private let configuration: ArchiveConfiguration
    private let database: ArchiveDatabase

    // nside=64 → ~55 arcmin per pixel; sufficient for astrophotography frame centres.
    private static let resolution = Resolution.nside64
    private let healpix = HEALPix(resolution: resolution, scheme: .ring)

    public init(configuration: ArchiveConfiguration) throws {
        self.configuration = configuration
        self.database = try ArchiveDatabase(
            url: configuration.databaseURL,
            archiveRootPath: configuration.rootURL.path
        )
        try FileManager.default.createDirectory(
            at: configuration.rootURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Path helpers

    private func toRelativePath(_ url: URL) -> String {
        let root = configuration.rootURL.path
        let path = url.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private func toAbsolutePath(_ relative: String) -> String {
        guard !relative.hasPrefix("/") else { return relative }
        return configuration.rootURL.path + "/" + relative
    }

    private func expandPath(_ frame: ArchivedFrame?) -> ArchivedFrame? {
        guard var f = frame else { return nil }
        f.filePath = toAbsolutePath(f.filePath)
        return f
    }

    private func expandPaths(_ frames: [ArchivedFrame]) -> [ArchivedFrame] {
        frames.map { var f = $0; f.filePath = toAbsolutePath(f.filePath); return f }
    }

    // MARK: - Ingestion

    /// Adds a single FITS file to the archive, copying it into the archive folder hierarchy.
    /// - Parameters:
    ///   - url: The source FITS file to copy into the archive.
    ///   - processingRunID: Optional ID of the processing run that produced this frame.
    /// - Returns: The frame record and `isNew: true` if it was inserted, `false` if already in archive.
    @discardableResult
    public func add(fitsFile url: URL, processingRunID: UUID? = nil) async throws -> (frame: ArchivedFrame, isNew: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveError.fileNotFound(url.path)
        }

        let meta = try FITSHeaderReader.read(from: url.path)

        // Auto-learn: when a frame carries camera name + gain setting + EGAIN,
        // record the mapping in camera_profiles so future frames without EGAIN
        // can benefit from the lookup.
        if let camera = meta.camera,
           let gainSetting = meta.gain,
           let knownEgain = meta.egain {
            try? await database.upsertCameraProfile(
                cameraName: camera, gainSetting: gainSetting, egain: knownEgain
            )
        }

        // Auto-lookup: when EGAIN is absent but camera + gain are known,
        // fill it from the camera_profiles table.
        let resolvedEgain: Double?
        if let e = meta.egain {
            resolvedEgain = e
        } else if let camera = meta.camera, let gainSetting = meta.gain {
            resolvedEgain = try? await database.lookupEGain(cameraName: camera, gainSetting: gainSetting)
        } else {
            resolvedEgain = nil
        }

        let healpixPixel: Int64? = {
            guard let ra = meta.ra, let dec = meta.dec else { return nil }
            let coord = AngularCoordinate(
                rightAscension: ra  * .pi / 180,
                declination:    dec * .pi / 180
            )
            return healpix.pixel(at: coord)
        }()

        let frameID = UUID()
        let dest = FolderOrganizer.destinationURL(
            for: meta, in: configuration.rootURL, filename: url.lastPathComponent, id: frameID
        )
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: url, to: dest)
        let filePath = toRelativePath(dest)

        let frame = ArchivedFrame(
            id: frameID,
            filePath: filePath,
            objectName: meta.objectName,
            ra: meta.ra, dec: meta.dec,
            healpixPixel: healpixPixel,
            frameType: meta.frameType,
            filter: ArchiveDatabase.canonicalFilterName(meta.filter),
            camera: meta.camera,
            telescope: meta.telescope,
            site: meta.site,
            focalLength: meta.focalLength,
            pixelScale: meta.pixelScale,
            temperature: meta.temperature,
            timestamp: meta.timestamp,
            exposureTime: meta.exposureTime,
            gain: meta.gain,
            offset: meta.offset,
            width: meta.width,
            height: meta.height,
            bitpix: meta.bitpix,
            calibrated: meta.calibrated,
            stacked: meta.stacked,
            stretched: meta.stretched,
            processingLevel: meta.processingLevel,
            addedAt: Date(),
            positionAngle: meta.positionAngle,
            processingRunID: processingRunID,
            sessionBeg: meta.sessionBeg,
            sessionEnd: meta.sessionEnd,
            temperatureMin: meta.temperatureMin,
            temperatureMax: meta.temperatureMax,
            fileDate: meta.fileDate,
            starCount: meta.starCount,
            medianFWHM: meta.medianFWHM,
            backgroundNoise: meta.backgroundNoise,
            medianEccentricity: meta.medianEccentricity,
            saturatedStarCount: meta.saturatedStarCount,
            hotPixelCount: meta.hotPixelCount,
            egain: resolvedEgain
        )
        let isNew = try await database.insertFrame(frame)
        if !isNew {
            try? FileManager.default.removeItem(at: dest)
            // Return the existing frame so the caller gets a valid, stored ID.
            let sig = ArchiveDatabase.frameSignature(
                fileDate: meta.fileDate,
                frameType: meta.frameType,
                filter: meta.filter,
                exposureTime: meta.exposureTime
            )
            if let existing = try await database.frameBySignature(sig) {
                return (expandPath(existing)!, false)
            }
        }
        return (expandPath(frame)!, isNew)
    }

    // MARK: - Processing runs

    /// Records a pipeline processing run and its input references for provenance tracking.
    ///
    /// Call this before archiving result frames so you have a run ID to link them to.
    /// - Parameters:
    ///   - pipelineID: The pipeline ID that was executed (e.g. "frame_stacking").
    ///   - parameters: Pipeline parameters that were active for this run.
    ///   - inputs: References to the input frames (archive IDs and/or file paths).
    /// - Returns: The persisted processing run record.
    @discardableResult
    public func recordProcessingRun(
        pipelineID: String,
        parameters: [String: String],
        inputs: [ProcessingRunInputRef]
    ) async throws -> ArchivedProcessingRun {
        let run = ArchivedProcessingRun(
            id: UUID(),
            pipelineID: pipelineID,
            parameters: parameters,
            createdAt: Date()
        )
        try await database.insertProcessingRun(run, inputs: inputs)
        return run
    }

    /// Returns a single frame by its absolute file path on disk.
    public func frame(filePath: String) async throws -> ArchivedFrame? {
        let relative = filePath.hasPrefix(configuration.rootURL.path + "/")
            ? String(filePath.dropFirst(configuration.rootURL.path.count + 1))
            : filePath
        return expandPath(try await database.frameByFilePath(relative))
    }

    /// Returns the processing run that produced a frame, together with its input references.
    /// Returns `nil` if the frame has no associated processing run.
    public func processingRun(for frame: ArchivedFrame) async throws -> (run: ArchivedProcessingRun, inputs: [ProcessingRunInputRef])? {
        guard let runID = frame.processingRunID else { return nil }
        guard let run = try await database.processingRunByID(runID) else { return nil }
        let inputs = try await database.inputsForRun(runID)
        return (run, inputs)
    }

    /// Adds all FITS files in a directory, copying each into the archive folder hierarchy.
    /// - Parameters:
    ///   - directory: Directory to scan.
    ///   - recursive: Descend into subdirectories.
    /// - Returns: A tuple of newly added frames and the count of files already in the archive.
    @discardableResult
    public func add(
        directory: URL,
        recursive: Bool = false
    ) async throws -> (added: [ArchivedFrame], skippedCount: Int) {
        let extensions = Set(["fits", "fit", "fts"])
        let options: FileManager.DirectoryEnumerationOptions =
            recursive ? [] : [.skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else { throw ArchiveError.fileNotFound(directory.path) }

        // Collect URLs synchronously before the async loop to avoid concurrency issues
        // with NSEnumerator's makeIterator.
        let urls = enumerator.compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension.lowercased()) }

        var added: [ArchivedFrame] = []
        var skippedCount = 0
        for fileURL in urls {
            let (frame, isNew) = try await add(fitsFile: fileURL)
            if isNew { added.append(frame) } else { skippedCount += 1 }
        }
        return (added, skippedCount)
    }

    // MARK: - Queries

    /// Returns all frames matching the given query.
    public func frames(matching query: FrameQuery = FrameQuery()) async throws -> [ArchivedFrame] {
        var healpixPixels: [Int64]?
        if let cone = query.coneSearch {
            let center = AngularCoordinate(
                rightAscension: cone.ra  * .pi / 180,
                declination:    cone.dec * .pi / 180
            )
            healpixPixels = healpix.pixels(
                inConeAround: center,
                radius: cone.radiusDeg * .pi / 180,
                inclusive: true
            )
        }
        return expandPaths(try await database.queryFrames(query, healpixPixels: healpixPixels))
    }

    /// Returns a single frame by its archive ID.
    public func frame(id: UUID) async throws -> ArchivedFrame? {
        expandPath(try await database.frameByID(id))
    }

    /// Returns the most recently archived frames, newest first.
    /// - Parameter limit: Maximum number of frames to return (default 15).
    public func recentFrames(limit: Int = 15) async throws -> [ArchivedFrame] {
        expandPaths(try await database.recentFrames(limit: limit))
    }

    /// Returns all archived objects with frame counts.
    public func listObjects() async throws -> [(name: String, count: Int)] {
        try await database.listObjects()
    }

    // MARK: - Statistics

    public func statistics() async throws -> ArchiveStatistics {
        try await database.statistics(archiveRoot: configuration.rootURL)
    }

    // MARK: - Quality metrics

    /// Result type for `backfillObservationMetadata`.
    public struct BackfillResult {
        /// Frames whose FITS file was read and at least one field updated.
        public let updated: Int
        /// Frames that already had all observation metadata and timestamp populated — no write needed.
        public let alreadyComplete: Int
        /// Frames whose FITS file could not be read (missing or corrupt).
        public let failed: Int
    }

    /// Re-reads FITS headers for existing archived frames and fills in missing
    /// `objectName`, `camera`, `telescope`, and `site` fields.
    ///
    /// Only frames that are missing at least one of the four fields are processed.
    /// Existing non-nil values are never overwritten.
    /// By default only `raw` frames are processed — stacked frames derive their
    /// instrument metadata from their inputs and are not expected to carry these
    /// headers directly.
    ///
    /// - Parameter processingLevels: Levels to include. Defaults to `[.raw]`.
    /// - Returns: A `BackfillResult` with counts of updated, already-complete, and failed frames.
    public func backfillObservationMetadata(
        processingLevels: [ProcessingLevel] = [.raw]
    ) async throws -> BackfillResult {
        var allFrames: [ArchivedFrame] = []
        for level in processingLevels {
            var q = FrameQuery()
            q.rejectionFilter = .includeAll
            q.processingLevel = level
            allFrames += try await frames(matching: q)
        }
        var updated = 0, alreadyComplete = 0, failed = 0

        for frame in allFrames {
            let needsMeta = frame.objectName == nil || frame.camera == nil
                            || frame.telescope == nil || frame.site == nil
            let needsDate = frame.timestamp == nil

            guard needsMeta || needsDate else { alreadyComplete += 1; continue }

            do {
                let meta = try FITSHeaderReader.read(from: toAbsolutePath(frame.filePath))
                var wroteAnything = false

                // Repair timestamp: write_result_frame_fits appends "Z" which the old
                // parseTimestamp didn't handle — frames ended up in unknown-date/.
                if needsDate, let ts = meta.timestamp {
                    try await database.updateTimestamp(id: frame.id, timestamp: ts)
                    wroteAnything = true
                }

                let newObj   = frame.objectName == nil ? meta.objectName : nil
                let newCam   = frame.camera     == nil ? meta.camera     : nil
                let newScope = frame.telescope  == nil ? meta.telescope  : nil
                let newSite  = frame.site       == nil ? meta.site       : nil
                if newObj != nil || newCam != nil || newScope != nil || newSite != nil {
                    try await database.updateObservationMetadata(
                        id: frame.id,
                        objectName: newObj,
                        camera: newCam,
                        telescope: newScope,
                        site: newSite
                    )
                    wroteAnything = true
                }

                if wroteAnything { updated += 1 } else { alreadyComplete += 1 }
            } catch {
                failed += 1
            }
        }
        return BackfillResult(updated: updated, alreadyComplete: alreadyComplete, failed: failed)
    }

    /// Updates quality metrics on an archived frame.
    ///
    /// Call this after running an analysis pipeline on the frame to persist the results.
    /// Only non-nil values are written; existing metrics are preserved for omitted parameters.
    ///
    /// - Parameters:
    ///   - id: The archive frame UUID.
    ///   - starCount: Number of detected stars (from frame_quality / star_detection pipeline).
    ///   - medianFWHM: Median FWHM in pixels, averaged over major and minor axes.
    ///   - backgroundNoise: Background level in ADU for light frames (frame_quality pipeline);
    ///     noise sigma in ADU for calibration frames (calibration_quality pipeline).
    ///     Legacy pipelines (star_detection, optical_quality) still write a normalised 0–1 value.
    ///   - medianEccentricity: Median star eccentricity (0=circular, 1=line).
    ///   - saturatedStarCount: Count of saturated stars (peak ≥ 90 % full-scale).
    ///   - hotPixelCount: Approximate count of hot pixels (calibration frames only).
    ///   - backgroundNoiseElectrons: Background level in electrons (light frames) or noise sigma
    ///     in electrons (calibration frames). Derived from backgroundNoise × egain. Only populated
    ///     when EGAIN is available. Cross-camera comparable.
    public func updateFrameQuality(
        id: UUID,
        starCount: Int? = nil,
        medianFWHM: Double? = nil,
        backgroundNoise: Double? = nil,
        medianEccentricity: Double? = nil,
        saturatedStarCount: Int? = nil,
        hotPixelCount: Int? = nil,
        backgroundNoiseElectrons: Double? = nil
    ) async throws {
        try await database.updateFrameQuality(
            id: id,
            starCount: starCount,
            medianFWHM: medianFWHM,
            backgroundNoise: backgroundNoise,
            medianEccentricity: medianEccentricity,
            saturatedStarCount: saturatedStarCount,
            hotPixelCount: hotPixelCount,
            backgroundNoiseElectrons: backgroundNoiseElectrons
        )
    }

    // MARK: - Stretch settings

    /// Persists the display stretch and current slider positions for a frame.
    ///
    /// All three values are written together in a single UPDATE. Always pass the current
    /// slider norms alongside any normalization change, or the slider positions will be
    /// cleared to NULL (equivalent to resetting them to their defaults on next open).
    ///
    /// - Parameters:
    ///   - settings: Normalization bounds. Pass `nil` to clear (reverts to identity).
    ///   - sliderBlackNorm: Black-point slider in [0, 1] of the full data range. `nil` clears.
    ///   - sliderWhiteNorm: White-point slider in [0, 1] of the full data range. `nil` clears.
    ///   - id: Archive frame UUID.
    ///
    /// The underlying FITS file is never modified — only the archive database is updated.
    public func updateStretchSettings(
        _ settings: StretchSettings?,
        sliderBlackNorm: Float? = nil,
        sliderWhiteNorm: Float? = nil,
        id: UUID
    ) async throws {
        try await database.updateStretchSettings(
            id: id,
            settings: settings,
            sliderBlackNorm: sliderBlackNorm,
            sliderWhiteNorm: sliderWhiteNorm
        )
    }

    // MARK: - Rejection

    /// Marks a frame as rejected so it is excluded from processing queries.
    public func reject(id: UUID, reason: String? = nil) async throws {
        try await database.updateRejected(id: id, rejected: true, reason: reason)
    }

    /// Clears the rejected flag from a frame.
    public func unreject(id: UUID) async throws {
        try await database.updateRejected(id: id, rejected: false, reason: nil)
    }

    // MARK: - Frame sets

    /// Inspects which frames would be included in a frame set matching `query`,
    /// reporting property distributions and any validation issues — without writing
    /// anything to the database.
    ///
    /// - Parameters:
    ///   - query: Frame filter. `maxFWHM` and `maxEccentricity` on the query are treated as
    ///     exclusion thresholds (frames are shown but marked as would-be-excluded).
    ///   - maxFWHM: Frames exceeding this FWHM (pixels) are shown as would-be-excluded.
    ///   - maxEccentricity: Frames exceeding this eccentricity are shown as would-be-excluded.
    public func inspectFrameSet(
        query: FrameQuery,
        maxFWHM: Double? = nil,
        maxEccentricity: Double? = nil
    ) async throws -> FrameSetInspection {
        var q = query
        q.rejectionFilter = .excludeRejected
        q.limit = nil
        // Strip quality threshold filters so all frames are returned for inspection.
        q.maxFWHM = nil
        q.maxEccentricity = nil
        let matchedFrames = try await frames(matching: q)
        let excludedByQuality = matchedFrames.filter { f in
            if let max = maxFWHM,        let v = f.medianFWHM,        v > max { return true }
            if let max = maxEccentricity, let v = f.medianEccentricity, v > max { return true }
            return false
        }
        return buildInspection(from: matchedFrames, excludedFrames: excludedByQuality)
    }

    /// Creates a frame set from all non-rejected frames matching `query`.
    ///
    /// Frames that exceed `maxFWHM` or `maxEccentricity` thresholds are **included** in the
    /// set but have their `excluded` flag set so that processing pipelines skip them by default.
    /// This differs from passing these values as `query.maxFWHM` / `query.maxEccentricity`,
    /// which would filter them out entirely.
    ///
    /// - Parameters:
    ///   - name: Display name for the set.
    ///   - query: Frame filter — rejected frames and any quality constraints (except FWHM/eccentricity)
    ///     are applied. Pass `maxFWHM`/`maxEccentricity` directly here, not via the query, to get
    ///     the "include-but-exclude" behaviour.
    ///   - force: When `true`, allows mixed optical filters.
    ///   - maxFWHM: Frames whose `medianFWHM` exceeds this value (pixels) are included but
    ///     marked as excluded. Frames without FWHM data are included and not marked.
    ///   - maxEccentricity: Frames whose `medianEccentricity` exceeds this value are included
    ///     but marked as excluded.
    /// - Returns: The persisted frame set together with its inspection report.
    @discardableResult
    public func createFrameSet(
        name: String,
        query: FrameQuery,
        force: Bool = false,
        maxFWHM: Double? = nil,
        maxEccentricity: Double? = nil
    ) async throws -> (frameSet: ArchivedFrameSet, inspection: FrameSetInspection) {
        var q = query
        q.rejectionFilter = .excludeRejected
        q.limit = nil
        // Strip quality threshold filters from the query — they are applied as exclusion flags instead.
        q.maxFWHM = nil
        q.maxEccentricity = nil
        let matchedFrames = try await frames(matching: q)

        // Determine which frames should be excluded based on quality thresholds.
        let excludedByQuality = matchedFrames.filter { f in
            if let max = maxFWHM,        let v = f.medianFWHM,        v > max { return true }
            if let max = maxEccentricity, let v = f.medianEccentricity, v > max { return true }
            return false
        }
        let excludedIDs = Set(excludedByQuality.map { $0.id })

        let inspection = buildInspection(from: matchedFrames, excludedFrames: excludedByQuality)

        guard !matchedFrames.isEmpty else {
            throw ArchiveError.frameSetError("No frames match the query.")
        }
        guard inspection.frameTypes.count == 1 else {
            let names = inspection.frameTypes.map { $0.label }.joined(separator: ", ")
            throw ArchiveError.frameSetError(
                "All frames must have the same type. Found: \(names)."
            )
        }
        guard inspection.processingLevels.count == 1 else {
            let names = inspection.processingLevels.map { $0.label }.joined(separator: ", ")
            throw ArchiveError.frameSetError(
                "All frames must have the same processing level. Found: \(names)."
            )
        }
        if !force && inspection.filters.count > 1 {
            let names = inspection.filters.map { $0.label }.joined(separator: ", ")
            throw ArchiveError.frameSetError(
                "Frames have mixed filters (\(names)). Use --force to create anyway."
            )
        }

        let frameType        = inspection.frameTypes[0].label
        let processingLevel  = ProcessingLevel(rawValue: inspection.processingLevels[0].label) ?? .raw
        let filterValue: String? = {
            if inspection.filters.count == 1 { return inspection.filters[0].label == "(none)" ? nil : inspection.filters[0].label }
            if force {
                let real = inspection.filters.map { $0.label }.filter { $0 != "(none)" }.sorted()
                return real.isEmpty ? nil : real.joined(separator: ",")
            }
            return nil
        }()

        // Build per-frame exclusion reasons.
        var excludedReasons: [UUID: String] = [:]
        for f in excludedByQuality {
            var reasons: [String] = []
            if let max = maxFWHM, let v = f.medianFWHM, v > max {
                reasons.append(String(format: "FWHM %.2f px > max %.2f px", v, max))
            }
            if let max = maxEccentricity, let v = f.medianEccentricity, v > max {
                reasons.append(String(format: "eccentricity %.3f > max %.3f", v, max))
            }
            if !reasons.isEmpty { excludedReasons[f.id] = reasons.joined(separator: "; ") }
        }

        let activeFrames = matchedFrames.filter { !excludedIDs.contains($0.id) }
        let frameSet = ArchivedFrameSet(
            id: UUID(), name: name, frameType: frameType, processingLevel: processingLevel,
            createdAt: Date(), frameCount: matchedFrames.count,
            excludedFrameCount: excludedIDs.count,
            objectName:   sharedString(matchedFrames.map { $0.objectName }),
            filter:       filterValue,
            camera:       sharedString(matchedFrames.map { $0.camera }),
            telescope:    sharedString(matchedFrames.map { $0.telescope }),
            site:         sharedString(matchedFrames.map { $0.site }),
            exposureTime: sharedDouble(matchedFrames.map { $0.exposureTime }),
            gain:         sharedDouble(matchedFrames.map { $0.gain }),
            offset:       sharedDouble(matchedFrames.map { $0.offset }),
            width:        sharedInt(matchedFrames.map    { $0.width }),
            height:       sharedInt(matchedFrames.map    { $0.height }),
            pixelScale:   sharedDouble(matchedFrames.map { $0.pixelScale }),
            focalLength:  sharedDouble(matchedFrames.map { $0.focalLength }),
            positionAngle: sharedDouble(matchedFrames.map { $0.positionAngle }),
            dateFrom: inspection.dateFrom,
            dateTo:   inspection.dateTo,
            temperatureMean: inspection.temperatureMean,
            temperatureMin:  inspection.temperatureMin,
            temperatureMax:  inspection.temperatureMax,
            medianStarCount:               median(activeFrames.compactMap { $0.starCount.map { Double($0) } }),
            medianFWHM:                    median(activeFrames.compactMap { $0.medianFWHM }),
            medianEccentricity:            median(activeFrames.compactMap { $0.medianEccentricity }),
            medianBackgroundNoise:         median(activeFrames.compactMap { $0.backgroundNoise }),
            medianBackgroundNoiseElectrons: median(activeFrames.compactMap { $0.backgroundNoiseElectrons })
        )
        try await database.insertFrameSet(
            frameSet,
            frameIDs: matchedFrames.map { $0.id },
            excludedIDs: excludedIDs,
            excludedReasons: excludedReasons
        )
        return (frameSet, inspection)
    }

    /// Returns frame sets matching the given query, ordered by creation date (newest first).
    public func frameSets(matching query: FrameSetQuery = FrameSetQuery()) async throws -> [ArchivedFrameSet] {
        try await database.queryFrameSets(matching: query)
    }

    /// Returns a single frame set by its ID.
    public func frameSet(id: UUID) async throws -> ArchivedFrameSet? {
        try await database.frameSetByID(id)
    }

    /// Returns the active (non-excluded) member frames of a frame set in stored order.
    ///
    /// This is the right method to use when feeding frames into a pipeline — excluded members
    /// are omitted. Use `members(inFrameSet:)` when you need the full membership including
    /// the exclusion state.
    public func frames(inFrameSet id: UUID) async throws -> [ArchivedFrame] {
        let frameIDs = try await database.frameIDsForSet(id, activeOnly: true)
        var result: [ArchivedFrame] = []
        for fid in frameIDs {
            if let f = try await database.frameByID(fid) { result.append(f) }
        }
        return expandPaths(result)
    }

    /// Returns all member frames of a frame set, including excluded ones, together with
    /// their per-set exclusion state. Use this for display purposes.
    public func members(inFrameSet id: UUID) async throws -> [FrameSetMember] {
        let rows = try await database.membersForSet(id)
        var result: [FrameSetMember] = []
        for (frameID, excluded, reason) in rows {
            guard let f = try await database.frameByID(frameID) else { continue }
            var expanded = f
            expanded.filePath = toAbsolutePath(f.filePath)
            result.append(FrameSetMember(frame: expanded, excluded: excluded, excludedReason: reason))
        }
        return result
    }

    /// Sets or clears the excluded flag for a single frame within a frame set.
    ///
    /// This is a per-frameset flag — the same frame can be excluded from one set while
    /// remaining active in another. It does not affect `ArchivedFrame.rejected`.
    public func setMemberExcluded(
        frameSetID: UUID,
        frameID: UUID,
        excluded: Bool,
        reason: String? = nil
    ) async throws {
        try await database.updateMemberExcluded(
            frameSetID: frameSetID,
            frameID: frameID,
            excluded: excluded,
            reason: excluded ? reason : nil
        )
    }

    /// Returns all frame set IDs that contain the given frame.
    public func frameSetIDs(forFrame frameID: UUID) async throws -> [UUID] {
        try await database.frameSetIDsForFrame(frameID)
    }

    /// Deletes a frame set. Member frames are not affected.
    public func deleteFrameSet(id: UUID) async throws {
        try await database.deleteFrameSet(id: id)
    }

    /// Recomputes quality aggregates (medians over active member frames) and persists them on the frameset.
    ///
    /// Call this after running a quality pipeline on frameset members so the summary reflects
    /// the latest per-frame metrics.
    public func recomputeFrameSetQuality(id: UUID) async throws {
        let activeFrames = try await frames(inFrameSet: id)
        try await database.updateFrameSetQuality(
            id: id,
            medianStarCount:               median(activeFrames.compactMap { $0.starCount.map { Double($0) } }),
            medianFWHM:                    median(activeFrames.compactMap { $0.medianFWHM }),
            medianEccentricity:            median(activeFrames.compactMap { $0.medianEccentricity }),
            medianBackgroundNoise:         median(activeFrames.compactMap { $0.backgroundNoise }),
            medianBackgroundNoiseElectrons: median(activeFrames.compactMap { $0.backgroundNoiseElectrons })
        )
    }

    // MARK: - Inspection builder

    private func buildInspection(
        from matchedFrames: [ArchivedFrame],
        excludedFrames: [ArchivedFrame] = []
    ) -> FrameSetInspection {
        func dist<T: Hashable>(_ values: [T?], nilLabel: String) -> [FrameSetInspection.Entry] {
            var counts: [String: Int] = [:]
            for v in values {
                let key = v.map { "\($0)" } ?? nilLabel
                counts[key, default: 0] += 1
            }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                         .map { FrameSetInspection.Entry(label: $0.key, count: $0.value) }
        }

        let frameTypes       = dist(matchedFrames.map { Optional($0.frameType) },          nilLabel: "(unknown)")
        let filters          = dist(matchedFrames.map { $0.filter },                        nilLabel: "(none)")
        let processingLevels = dist(matchedFrames.map { Optional($0.processingLevel.rawValue) }, nilLabel: "(unknown)")
        let objectNames      = dist(matchedFrames.map { $0.objectName },                    nilLabel: "(unknown)")
        let cameras          = dist(matchedFrames.map { $0.camera },                        nilLabel: "(unknown)")

        // Pixel scales grouped to 3 decimal places
        var pixelScaleCounts: [String: Int] = [:]
        for f in matchedFrames {
            if let ps = f.pixelScale {
                pixelScaleCounts[String(format: "%.3f \"/px", ps), default: 0] += 1
            }
        }
        let pixelScales = pixelScaleCounts.sorted { $0.key < $1.key }
            .map { FrameSetInspection.Entry(label: $0.key, count: $0.value) }

        // Focal lengths grouped to nearest mm
        var focalLengthCounts: [String: Int] = [:]
        for f in matchedFrames {
            if let fl = f.focalLength {
                focalLengthCounts[String(format: "%.0f mm", fl), default: 0] += 1
            }
        }
        let focalLengths = focalLengthCounts.sorted { $0.key < $1.key }
            .map { FrameSetInspection.Entry(label: $0.key, count: $0.value) }

        // Position angles grouped to 1 decimal place
        var posAngleCounts: [String: Int] = [:]
        for f in matchedFrames {
            if let pa = f.positionAngle {
                posAngleCounts[String(format: "%.1f°", pa), default: 0] += 1
            }
        }
        let positionAngles = posAngleCounts.sorted { $0.key < $1.key }
            .map { FrameSetInspection.Entry(label: $0.key, count: $0.value) }

        // Date span
        let timestamps = matchedFrames.compactMap { $0.timestamp }
        let dateFrom = timestamps.min()
        let dateTo   = timestamps.max()

        // Temperature stats
        let temps = matchedFrames.compactMap { $0.temperature }
        let temperatureMin  = temps.isEmpty ? nil : temps.min()
        let temperatureMax  = temps.isEmpty ? nil : temps.max()
        let temperatureMean = temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)

        // Validation
        var issues: [String] = []
        var canCreate = !matchedFrames.isEmpty
        var needsForce = false

        if matchedFrames.isEmpty {
            issues.append("No frames match the query.")
        }
        if frameTypes.count > 1 {
            let names = frameTypes.map { $0.label }.joined(separator: ", ")
            issues.append("Mixed frame types (\(names)) — fatal, cannot create.")
            canCreate = false
        }
        if processingLevels.count > 1 {
            let names = processingLevels.map { $0.label }.joined(separator: ", ")
            issues.append("Mixed processing levels (\(names)) — fatal, cannot create.")
            canCreate = false
        }
        if filters.count > 1 {
            let names = filters.map { $0.label }.joined(separator: ", ")
            issues.append("Mixed filters (\(names)) — use --force to override.")
            needsForce = true
        }

        return FrameSetInspection(
            matchedFrameCount: matchedFrames.count,
            frameTypes: frameTypes, filters: filters,
            processingLevels: processingLevels, objectNames: objectNames,
            cameras: cameras, pixelScales: pixelScales,
            focalLengths: focalLengths, positionAngles: positionAngles,
            dateFrom: dateFrom, dateTo: dateTo,
            temperatureMin: temperatureMin, temperatureMax: temperatureMax,
            temperatureMean: temperatureMean,
            canCreate: canCreate, needsForce: needsForce, issues: issues,
            frames: matchedFrames,
            excludedFrames: excludedFrames
        )
    }

    // MARK: - Math helpers

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 : sorted[n / 2]
    }

    // MARK: - Shared property helpers

    private func sharedString(_ values: [String?]) -> String? {
        // Nil frames don't vote: a frame that lacks the field does not prevent
        // a unanimous result from being derived from the frames that have it.
        let nonNil = values.compactMap { $0 }
        guard !nonNil.isEmpty else { return nil }
        let unique = Set(nonNil)
        return unique.count == 1 ? unique.first : nil
    }

    private func sharedDouble(_ values: [Double?]) -> Double? {
        let nonNil = values.compactMap { $0 }
        guard nonNil.count == values.count, let first = nonNil.first else { return nil }
        return nonNil.allSatisfy { abs($0 - first) < 0.001 } ? first : nil
    }

    private func sharedInt(_ values: [Int?]) -> Int? {
        let nonNil = values.compactMap { $0 }
        guard nonNil.count == values.count else { return nil }
        let unique = Set(nonNil)
        return unique.count == 1 ? unique.first : nil
    }

    // MARK: - Removal

    /// Removes a frame from the archive index.
    /// - Parameter deleteFile: Also deletes the FITS file from disk.
    public func remove(id: UUID, deleteFile: Bool = false) async throws {
        if deleteFile, let relative = try await database.frameFilePath(id: id) {
            let url = URL(fileURLWithPath: toAbsolutePath(relative))
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await database.deleteFrame(id: id)
    }
}
