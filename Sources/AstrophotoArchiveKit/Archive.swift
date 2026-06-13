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

    private func expandPath(_ frame: ArchivedFrame) -> ArchivedFrame {
        var f = frame
        f.filePath = toAbsolutePath(f.filePath)
        return f
    }

    private func expandPath(_ frame: ArchivedFrame?) -> ArchivedFrame? {
        frame.map { expandPath($0) }
    }

    private func expandPaths(_ frames: [ArchivedFrame]) -> [ArchivedFrame] {
        frames.map { var f = $0; f.filePath = toAbsolutePath(f.filePath); return f }
    }

    // MARK: - Ingestion

    /// Adds a single FITS file to the archive, copying it into the archive folder hierarchy.
    /// - Parameters:
    ///   - url: The source FITS file to copy into the archive.
    ///   - processingRunID: Optional ID of the processing run that produced this frame.
    ///     When the frame already exists in the archive (duplicate signature) and this
    ///     value is non-nil and differs from the stored run ID, the stored ID is updated
    ///     to reflect the most recent run. Pass `nil` to leave the existing run ID intact.
    ///   - supersedesID: Optional ID of an earlier pipeline result that this frame replaces.
    ///     Use this to link successive pipeline runs into a lineage chain (newest → oldest).
    ///     Applies to any pipeline output — stacking, calibration, registration, etc.
    /// - Returns: The frame record and `isNew: true` if it was inserted, `false` if already in archive.
    @discardableResult
    public func add(fitsFile url: URL, processingRunID: UUID? = nil, supersedesID: UUID? = nil) async throws -> (frame: ArchivedFrame, isNew: Bool) {
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
            supersedesID: supersedesID,
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
        // Only raw frames are deduplicated by content signature, to prevent accidental
        // double-import of the same physical observation. All other levels are pipeline
        // outputs that must always be stored as independent records:
        //   .calibrated — bias/dark/flat-corrected single frame
        //   .stacked    — result of a stacking pipeline run
        //   .stretched  — result of a destructive stretch pipeline (STRETCHD = T in FITS)
        //                 Note: the non-destructive display stretch (Archive.updateStretchSettings)
        //                 does NOT set this level; no pipeline currently writes STRETCHD = T.
        let deduplicate = frame.processingLevel == .raw
        let isNew = try await database.insertFrame(frame, deduplicate: deduplicate)
        if !isNew {
            try? FileManager.default.removeItem(at: dest)
            // Return the existing frame so the caller gets a valid, stored ID.
            let sig = ArchiveDatabase.frameSignature(
                fileDate: meta.fileDate,
                frameType: meta.frameType,
                filter: meta.filter,
                exposureTime: meta.exposureTime
            )
            if var existing = try await database.frameBySignature(sig) {
                if let runID = processingRunID, runID != existing.processingRunID {
                    try await database.updateFrameRunID(id: existing.id, processingRunID: runID)
                    existing.processingRunID = runID
                }
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

    // MARK: - Lineage

    /// Returns the complete lineage chain for a frame, ordered from newest to oldest.
    ///
    /// Walks the `supersedesID` linked list starting from the given frame and returns every
    /// ancestor in order: `[frame, predecessor, predecessor's predecessor, …]`.
    /// The chain terminates when a frame has no `supersedesID`, or after 1 000 steps to
    /// guard against cycles caused by data corruption.
    ///
    /// - Parameter frame: The frame to start the walk from (included as the first element).
    /// - Returns: The frame followed by its ancestors in lineage order.
    public func lineage(of frame: ArchivedFrame) async throws -> [ArchivedFrame] {
        var chain: [ArchivedFrame] = [frame]
        var current = frame
        while let predecessorID = current.supersedesID, chain.count < 1_000 {
            guard let predecessor = try await database.frameByID(predecessorID) else { break }
            chain.append(expandPath(predecessor))
            current = predecessor
        }
        return chain
    }

    /// Returns all frames that directly supersede the given frame — i.e. results from a
    /// later pipeline run that explicitly linked themselves to this frame as their predecessor.
    public func successors(of frame: ArchivedFrame) async throws -> [ArchivedFrame] {
        let frames = try await database.successors(of: frame.id)
        return expandPaths(frames)
    }

    /// Updates the lineage link on a frame.
    ///
    /// - Parameters:
    ///   - frameID: The frame whose `supersedesID` should be updated.
    ///   - supersedesID: The ID of the earlier result this frame replaces,
    ///     or `nil` to detach the frame from its current predecessor.
    public func updateSupersedesID(frameID: UUID, supersedesID: UUID?) async throws {
        try await database.updateFrameSupersedesID(id: frameID, supersedesID: supersedesID)
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
    /// - Parameters:
    ///   - limit: Maximum number of frames to return (default 15); pass `nil` to return all frames.
    ///   - rejectionFilter: Whether to include, exclude, or exclusively show rejected frames (default `.excludeRejected`).
    public func recentFrames(limit: Int? = 15, rejectionFilter: RejectionFilter = .excludeRejected) async throws -> [ArchivedFrame] {
        expandPaths(try await database.recentFrames(limit: limit, rejectionFilter: rejectionFilter))
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
        /// Frames for which no write was performed — either all fields were already populated,
        /// or the FITS file had nothing new to contribute for the fields that were missing.
        public let skipped: Int
        /// Frames whose FITS file could not be read (missing or corrupt).
        public let failed: Int
        /// Absolute paths of the FITS files that could not be read.
        public let failedPaths: [String]
        /// Framesets whose pixel scale was filled in from their member frames.
        public let frameSetsUpdated: Int
    }

    /// Re-reads FITS headers for existing archived frames and fills in missing fields:
    /// - Observation strings: `objectName`, `camera`, `telescope`, `site`
    /// - Numeric acquisition data: `exposureTime`, `gain`, `offset`, `temperature`,
    ///   `egain`, `focalLength`, `pixelScale`, `positionAngle`
    /// - `timestamp` (repairs frames archived before the DATE-OBS "Z" suffix was handled)
    ///
    /// Only frames missing at least one field are processed. Existing non-nil values are
    /// never overwritten. When `exposureTime` is recovered the frame signature is recomputed
    /// to keep the deduplication index consistent.
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
        var updated = 0, skipped = 0, failed = 0
        var failedPaths: [String] = []

        for frame in allFrames {
            // Only light and diagnostic frames can be missing a target object — calibration
            // frames never carry one (ASTR-51), so their permanently-nil object must not
            // trigger a FITS re-read on every backfill run.
            let needsObject = ["light", "diagnostic"].contains(frame.frameType)
                            && frame.objectName == nil
            let needsMeta = needsObject || frame.camera == nil
                            || frame.telescope == nil || frame.site == nil
            let needsDate = frame.timestamp == nil
            let needsNumeric = frame.exposureTime == nil || frame.gain == nil
                            || frame.offset == nil || frame.temperature == nil
                            || frame.egain == nil || frame.focalLength == nil
                            || frame.pixelScale == nil || frame.positionAngle == nil

            guard needsMeta || needsDate || needsNumeric else { skipped += 1; continue }

            do {
                let meta = try FITSHeaderReader.read(from: toAbsolutePath(frame.filePath))
                var wroteAnything = false

                // Repair timestamp: write_result_frame_fits appends "Z" which the old
                // parseTimestamp didn't handle — frames ended up in unknown-date/.
                if needsDate, let ts = meta.timestamp {
                    try await database.updateTimestamp(id: frame.id, timestamp: ts)
                    wroteAnything = true
                }

                // Guard on needsObject (not just nil) so a calibration frame whose FITS
                // file still carries a leftover OBJECT keyword can never get it written
                // back, even if a future reader regression returns one (ASTR-51).
                let newObj   = needsObject ? meta.objectName : nil
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

                let newExp   = frame.exposureTime  == nil ? meta.exposureTime  : nil
                let newGain  = frame.gain          == nil ? meta.gain          : nil
                let newOff   = frame.offset        == nil ? meta.offset        : nil
                let newTemp  = frame.temperature   == nil ? meta.temperature   : nil
                let newEgain = frame.egain         == nil ? meta.egain         : nil
                let newFL    = frame.focalLength   == nil ? meta.focalLength   : nil
                let newPS    = frame.pixelScale    == nil ? meta.pixelScale    : nil
                let newPA    = frame.positionAngle == nil ? meta.positionAngle : nil
                if newExp != nil || newGain != nil || newOff != nil || newTemp != nil
                    || newEgain != nil || newFL != nil || newPS != nil || newPA != nil {
                    // If exposureTime is being written, recompute frame_signature so the
                    // deduplication index stays consistent with the corrected value.
                    let newSig: String? = newExp.map { exp in
                        ArchiveDatabase.frameSignature(
                            fileDate: frame.fileDate ?? frame.timestamp,
                            frameType: frame.frameType,
                            filter: frame.filter,
                            exposureTime: exp
                        )
                    }
                    try await database.updateAcquisitionMetadata(
                        id: frame.id,
                        exposureTime: newExp,
                        gain: newGain,
                        offset: newOff,
                        temperature: newTemp,
                        egain: newEgain,
                        focalLength: newFL,
                        pixelScale: newPS,
                        positionAngle: newPA,
                        newFrameSignature: newSig
                    )
                    wroteAnything = true
                }

                if wroteAnything { updated += 1 } else { skipped += 1 }
            } catch {
                failed += 1
                failedPaths.append(toAbsolutePath(frame.filePath))
            }
        }

        // Framesets created before their member frames had a pixel scale carry NULL —
        // fill them from the (now possibly backfilled) members.
        let frameSetsUpdated = try await propagatePixelScaleToFrameSets()

        return BackfillResult(
            updated: updated, skipped: skipped, failed: failed,
            failedPaths: failedPaths, frameSetsUpdated: frameSetsUpdated
        )
    }

    // MARK: - Pixel scale

    /// Bulk-sets the pixel scale (arcsec/px) on all frames and framesets whose
    /// telescope and/or camera match the given values (exact match).
    ///
    /// Use this to repair archives from sources that record neither a scale keyword
    /// nor the optics headers needed to derive one. Stacked result frames inherit
    /// telescope/camera from their inputs, so they are matched by the same call.
    /// Framesets that don't match directly (e.g. their telescope is NULL because it
    /// was never aggregated) are still filled in when their member frames now agree
    /// on a single pixel scale.
    ///
    /// - Parameters:
    ///   - arcsecPerPixel: The image scale to set, in arcseconds per pixel.
    ///   - telescope: Match frames with this exact telescope name (FITS `TELESCOP`).
    ///   - camera: Match frames with this exact camera name (FITS `INSTRUME`).
    ///   - overwrite: When false (default) only fills NULL values; when true,
    ///     replaces existing pixel scales on matching records as well.
    /// - Returns: The number of frame and frameset records updated.
    /// - Throws: `ArchiveError.invalidArgument` when the scale is not positive or
    ///   neither telescope nor camera is given (which would update the whole archive).
    public func setPixelScale(
        _ arcsecPerPixel: Double,
        telescope: String? = nil,
        camera: String? = nil,
        overwrite: Bool = false
    ) async throws -> (frames: Int, frameSets: Int) {
        guard arcsecPerPixel > 0 else {
            throw ArchiveError.invalidArgument("pixel scale must be positive (got \(arcsecPerPixel))")
        }
        guard telescope != nil || camera != nil else {
            throw ArchiveError.invalidArgument(
                "setPixelScale requires a telescope and/or camera to match — " +
                "updating every frame in the archive is almost certainly a mistake")
        }
        var (frames, frameSets) = try await database.bulkSetPixelScale(
            arcsecPerPixel, telescope: telescope, camera: camera, overwrite: overwrite
        )
        frameSets += try await propagatePixelScaleToFrameSets()
        return (frames, frameSets)
    }

    /// Fills NULL frameset pixel scales from member frames that unanimously agree
    /// on a value (nil members don't vote). Returns the number of framesets updated.
    private func propagatePixelScaleToFrameSets() async throws -> Int {
        var updated = 0
        for fs in try await frameSets() where fs.pixelScale == nil {
            let members = try await frames(inFrameSet: fs.id)
            if let scale = sharedDouble(members.map { $0.pixelScale }) {
                try await database.updateFrameSetPixelScale(id: fs.id, pixelScale: scale)
                updated += 1
            }
        }
        return updated
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
        let excludedByQuality = matchedFrames.filter {
            qualityExclusionReason(for: $0, maxFWHM: maxFWHM, maxEccentricity: maxEccentricity) != nil
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
        var excludedReasons: [UUID: String] = [:]
        for f in matchedFrames {
            if let reason = qualityExclusionReason(for: f, maxFWHM: maxFWHM, maxEccentricity: maxEccentricity) {
                excludedReasons[f.id] = reason
            }
        }
        let excludedIDs = Set(excludedReasons.keys)
        let excludedByQuality = matchedFrames.filter { excludedIDs.contains($0.id) }

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
                "Frames have mixed filters (\(names)). Enable force to create anyway."
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
            medianBackgroundNoiseElectrons: median(activeFrames.compactMap { $0.backgroundNoiseElectrons }),
            // Persist the cleaned query plus the exclusion thresholds so frames added
            // later can be validated against the same criteria.
            criteria: FrameSetCriteria(query: q, maxFWHM: maxFWHM, maxEccentricity: maxEccentricity)
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

    /// Adds frames to an existing frame set.
    ///
    /// Each frame must match the set's invariants: same frame type, same processing level,
    /// and an optical filter compatible with the set's filter(s). When the set carries
    /// persisted creation criteria (sets created since schema v27), the frames must also
    /// match the query the set was created with. Frames exceeding the set's quality
    /// thresholds (`maxFWHM` / `maxEccentricity` from the creation criteria) are added
    /// but marked excluded — the same include-but-exclude semantics as set creation.
    ///
    /// - Parameters:
    ///   - setID: The frame set to add to.
    ///   - frameIDs: Archive frame UUIDs to add. Frames already in the set are skipped.
    ///   - force: Skips the filter and creation-criteria checks (frame type and
    ///     processing level always must match). Mirrors `--force` on set creation.
    /// - Throws: `ArchiveError.frameSetError` when the set or a frame does not exist,
    ///   a frame is rejected, or a frame fails validation.
    @discardableResult
    public func addFrames(
        toFrameSet setID: UUID,
        frameIDs: [UUID],
        force: Bool = false
    ) async throws -> FrameSetAddResult {
        guard let set = try await database.frameSetByID(setID) else {
            throw ArchiveError.frameSetError("No frame set with id \(setID.uuidString).")
        }
        let existingIDs = Set(try await database.frameIDsForSet(setID))

        // Resolve candidates, skipping duplicates in the input and existing members.
        var alreadyMembers: [UUID] = []
        var candidates: [ArchivedFrame] = []
        var seen = Set<UUID>()
        for fid in frameIDs {
            guard seen.insert(fid).inserted else { continue }
            guard let frame = try await database.frameByID(fid) else {
                throw ArchiveError.frameSetError("No frame with id \(fid.uuidString) in the archive.")
            }
            if existingIDs.contains(fid) {
                alreadyMembers.append(fid)
            } else {
                candidates.append(frame)
            }
        }

        for frame in candidates {
            let label = (frame.filePath as NSString).lastPathComponent
            if frame.rejected {
                let reason = frame.rejectedReason.map { " (\($0))" } ?? ""
                throw ArchiveError.frameSetError(
                    "Frame \(frame.id.uuidString) [\(label)] is rejected\(reason). "
                    + "Un-reject it first."
                )
            }
            guard frame.frameType.lowercased() == set.frameType.lowercased() else {
                throw ArchiveError.frameSetError(
                    "Frame \(frame.id.uuidString) [\(label)] has type '\(frame.frameType)' "
                    + "but the set contains '\(set.frameType)' frames."
                )
            }
            guard frame.processingLevel == set.processingLevel else {
                throw ArchiveError.frameSetError(
                    "Frame \(frame.id.uuidString) [\(label)] has processing level "
                    + "'\(frame.processingLevel.rawValue)' but the set contains "
                    + "'\(set.processingLevel.rawValue)' frames."
                )
            }
            if !force && !filterAllowed(frame.filter, inSet: set.filter) {
                let setFilter   = set.filter ?? "(none)"
                let frameFilter = frame.filter ?? "(none)"
                throw ArchiveError.frameSetError(
                    "Frame \(frame.id.uuidString) [\(label)] has filter '\(frameFilter)' "
                    + "but the set was created with filter '\(setFilter)'. Enable force to add anyway."
                )
            }
        }

        // Validate against the persisted creation criteria: the candidate must be in the
        // result of the same query the set was created with. Re-running the query reuses
        // all SQL predicate logic (object, camera, quality filters, …).
        // dateRange is stripped: the common case is extending a set with newer frames
        // that fall outside the original capture window. Type, level, and filter are
        // still enforced by the invariant checks above.
        if !force, let criteria = set.criteria {
            var q = criteria.query
            q.rejectionFilter = .excludeRejected
            q.limit = nil
            q.dateRange = nil
            q.maxFWHM = nil
            q.maxEccentricity = nil
            let matchingIDs = Set(try await frames(matching: q).map { $0.id })
            for frame in candidates where !matchingIDs.contains(frame.id) {
                let label = (frame.filePath as NSString).lastPathComponent
                throw ArchiveError.frameSetError(
                    "Frame \(frame.id.uuidString) [\(label)] does not match the criteria "
                    + "this set was created with. Enable force to add anyway."
                )
            }
        }

        // Quality thresholds from the creation criteria: include-but-exclude, as on creation.
        var excludedReasons: [UUID: String] = [:]
        if let criteria = set.criteria {
            for f in candidates {
                if let reason = qualityExclusionReason(
                    for: f, maxFWHM: criteria.maxFWHM, maxEccentricity: criteria.maxEccentricity
                ) {
                    excludedReasons[f.id] = reason
                }
            }
        }

        guard !candidates.isEmpty else {
            return FrameSetAddResult(
                frameSet: set, addedIDs: [],
                alreadyMemberIDs: alreadyMembers, excludedReasons: [:]
            )
        }

        try await database.addFrameSetMembers(
            setID: setID,
            frameIDs: candidates.map { $0.id },
            excludedIDs: Set(excludedReasons.keys),
            excludedReasons: excludedReasons
        )
        let updated = try await recomputeFrameSetAggregates(id: setID)
        return FrameSetAddResult(
            frameSet: updated,
            addedIDs: candidates.map { $0.id },
            alreadyMemberIDs: alreadyMembers,
            excludedReasons: excludedReasons
        )
    }

    /// Removes frames from an existing frame set. The frames themselves stay in the archive.
    ///
    /// Frames that are not members of the set are skipped and reported in the result.
    /// Removing all remaining members is refused — delete the set instead.
    @discardableResult
    public func removeFrames(
        fromFrameSet setID: UUID,
        frameIDs: [UUID]
    ) async throws -> FrameSetRemoveResult {
        guard let set = try await database.frameSetByID(setID) else {
            throw ArchiveError.frameSetError("No frame set with id \(setID.uuidString).")
        }
        let existingIDs = Set(try await database.frameIDsForSet(setID))

        var toRemove: [UUID] = []
        var notMembers: [UUID] = []
        var seen = Set<UUID>()
        for fid in frameIDs {
            guard seen.insert(fid).inserted else { continue }
            if existingIDs.contains(fid) {
                toRemove.append(fid)
            } else {
                notMembers.append(fid)
            }
        }

        guard !toRemove.isEmpty else {
            return FrameSetRemoveResult(frameSet: set, removedIDs: [], notMemberIDs: notMembers)
        }
        guard toRemove.count < existingIDs.count else {
            throw ArchiveError.frameSetError(
                "Removing \(toRemove.count) frame\(toRemove.count == 1 ? "" : "s") would leave "
                + "the set empty. Use 'ap-archive frameset delete' to delete the whole set instead."
            )
        }

        _ = try await database.removeFrameSetMembers(setID: setID, frameIDs: toRemove)
        let updated = try await recomputeFrameSetAggregates(id: setID)
        return FrameSetRemoveResult(frameSet: updated, removedIDs: toRemove, notMemberIDs: notMembers)
    }

    /// Whether a frame's optical filter is compatible with a set's filter field.
    /// The set field is a single name, a comma-separated list (force-created sets),
    /// or nil when the members carry no filter.
    private func filterAllowed(_ frameFilter: String?, inSet setFilter: String?) -> Bool {
        guard let setFilter else { return frameFilter == nil }
        guard let frameFilter else { return false }
        let allowed = setFilter.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return allowed.contains(frameFilter.lowercased())
    }

    /// Recomputes the stored aggregates (shared scalars, filter list, date span,
    /// temperature statistics, and quality medians) from the current membership and
    /// persists them. Returns the refreshed frame set.
    @discardableResult
    private func recomputeFrameSetAggregates(id: UUID) async throws -> ArchivedFrameSet {
        guard var fs = try await database.frameSetByID(id) else {
            throw ArchiveError.frameSetError("No frame set with id \(id.uuidString).")
        }
        let allIDs = try await database.frameIDsForSet(id)
        var allFrames: [ArchivedFrame] = []
        for fid in allIDs {
            if let f = try await database.frameByID(fid) { allFrames.append(f) }
        }
        let activeIDs = Set(try await database.frameIDsForSet(id, activeOnly: true))
        let activeFrames = allFrames.filter { activeIDs.contains($0.id) }

        // Filter column: single shared name, or a sorted comma-separated list when the
        // membership is mixed (only reachable on force-created or force-extended sets).
        let realFilters = Set(allFrames.compactMap { $0.filter })
        fs.filter = realFilters.count == 1
            ? realFilters.first
            : (realFilters.isEmpty ? nil : realFilters.sorted().joined(separator: ","))

        fs.objectName    = sharedString(allFrames.map { $0.objectName })
        fs.camera        = sharedString(allFrames.map { $0.camera })
        fs.telescope     = sharedString(allFrames.map { $0.telescope })
        fs.site          = sharedString(allFrames.map { $0.site })
        fs.exposureTime  = sharedDouble(allFrames.map { $0.exposureTime })
        fs.gain          = sharedDouble(allFrames.map { $0.gain })
        fs.offset        = sharedDouble(allFrames.map { $0.offset })
        fs.width         = sharedInt(allFrames.map    { $0.width })
        fs.height        = sharedInt(allFrames.map    { $0.height })
        fs.pixelScale    = sharedDouble(allFrames.map { $0.pixelScale })
        fs.focalLength   = sharedDouble(allFrames.map { $0.focalLength })
        fs.positionAngle = sharedDouble(allFrames.map { $0.positionAngle })

        let timestamps = allFrames.compactMap { $0.timestamp }
        fs.dateFrom = timestamps.min()
        fs.dateTo   = timestamps.max()

        let temps = allFrames.compactMap { $0.temperature }
        fs.temperatureMin  = temps.min()
        fs.temperatureMax  = temps.max()
        fs.temperatureMean = temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)

        fs.medianStarCount                = median(activeFrames.compactMap { $0.starCount.map { Double($0) } })
        fs.medianFWHM                     = median(activeFrames.compactMap { $0.medianFWHM })
        fs.medianEccentricity             = median(activeFrames.compactMap { $0.medianEccentricity })
        fs.medianBackgroundNoise          = median(activeFrames.compactMap { $0.backgroundNoise })
        fs.medianBackgroundNoiseElectrons = median(activeFrames.compactMap { $0.backgroundNoiseElectrons })

        fs.frameCount         = allFrames.count
        fs.excludedFrameCount = allFrames.count - activeFrames.count

        try await database.updateFrameSetAggregates(fs)
        return fs
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
            issues.append("Mixed filters (\(names)) — enable force to override.")
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

    private func qualityExclusionReason(
        for frame: ArchivedFrame,
        maxFWHM: Double?,
        maxEccentricity: Double?
    ) -> String? {
        var reasons: [String] = []
        if let max = maxFWHM, let v = frame.medianFWHM, v > max {
            reasons.append(String(format: "FWHM %.2f px > max %.2f px", v, max))
        }
        if let max = maxEccentricity, let v = frame.medianEccentricity, v > max {
            reasons.append(String(format: "eccentricity %.3f > max %.3f", v, max))
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

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
