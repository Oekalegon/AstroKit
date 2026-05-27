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
        self.database = try ArchiveDatabase(url: configuration.databaseURL)
        try FileManager.default.createDirectory(
            at: configuration.rootURL,
            withIntermediateDirectories: true
        )
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
        let filePath = dest.path

        let frame = ArchivedFrame(
            id: frameID,
            filePath: filePath,
            objectName: meta.objectName,
            ra: meta.ra, dec: meta.dec,
            healpixPixel: healpixPixel,
            frameType: meta.frameType,
            filter: meta.filter,
            camera: meta.camera,
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
            fileDate: meta.fileDate
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
                return (existing, false)
            }
        }
        return (frame, isNew)
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
        try await database.frameByFilePath(filePath)
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
        return try await database.queryFrames(query, healpixPixels: healpixPixels)
    }

    /// Returns a single frame by its archive ID.
    public func frame(id: UUID) async throws -> ArchivedFrame? {
        try await database.frameByID(id)
    }

    /// Returns the most recently archived frames, newest first.
    /// - Parameter limit: Maximum number of frames to return (default 15).
    public func recentFrames(limit: Int = 15) async throws -> [ArchivedFrame] {
        try await database.recentFrames(limit: limit)
    }

    /// Returns all archived objects with frame counts.
    public func listObjects() async throws -> [(name: String, count: Int)] {
        try await database.listObjects()
    }

    // MARK: - Statistics

    public func statistics() async throws -> ArchiveStatistics {
        try await database.statistics(archiveRoot: configuration.rootURL)
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
    public func inspectFrameSet(query: FrameQuery) async throws -> FrameSetInspection {
        var q = query
        q.rejectionFilter = .excludeRejected
        q.limit = nil
        let matchedFrames = try await frames(matching: q)
        return buildInspection(from: matchedFrames)
    }

    /// Creates a frame set from all non-rejected frames matching `query`.
    ///
    /// - Parameters:
    ///   - name: Display name for the set.
    ///   - query: Frame filter — rejected frames are always excluded.
    ///   - force: When `true`, allows mixed optical filters (stored as a comma-separated
    ///     list). Mixed frame types and processing levels are always fatal.
    /// - Returns: The persisted frame set together with its inspection report.
    @discardableResult
    public func createFrameSet(
        name: String,
        query: FrameQuery,
        force: Bool = false
    ) async throws -> (frameSet: ArchivedFrameSet, inspection: FrameSetInspection) {
        var q = query
        q.rejectionFilter = .excludeRejected
        q.limit = nil
        let matchedFrames = try await frames(matching: q)
        let inspection = buildInspection(from: matchedFrames)

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

        let frameSet = ArchivedFrameSet(
            id: UUID(), name: name, frameType: frameType, processingLevel: processingLevel,
            createdAt: Date(), frameCount: matchedFrames.count,
            objectName:   sharedString(matchedFrames.map { $0.objectName }),
            filter:       filterValue,
            camera:       sharedString(matchedFrames.map { $0.camera }),
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
            temperatureMax:  inspection.temperatureMax
        )
        try await database.insertFrameSet(frameSet, frameIDs: matchedFrames.map { $0.id })
        return (frameSet, inspection)
    }

    /// Returns all frame sets ordered by creation date (newest first).
    public func frameSets() async throws -> [ArchivedFrameSet] {
        try await database.queryFrameSets()
    }

    /// Returns a single frame set by its ID.
    public func frameSet(id: UUID) async throws -> ArchivedFrameSet? {
        try await database.frameSetByID(id)
    }

    /// Returns the member frames of a frame set in their stored order.
    public func frames(inFrameSet id: UUID) async throws -> [ArchivedFrame] {
        let frameIDs = try await database.frameIDsForSet(id)
        var result: [ArchivedFrame] = []
        for fid in frameIDs {
            if let f = try await database.frameByID(fid) { result.append(f) }
        }
        return result
    }

    /// Deletes a frame set. Member frames are not affected.
    public func deleteFrameSet(id: UUID) async throws {
        try await database.deleteFrameSet(id: id)
    }

    // MARK: - Inspection builder

    private func buildInspection(from matchedFrames: [ArchivedFrame]) -> FrameSetInspection {
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
            frames: matchedFrames
        )
    }

    // MARK: - Shared property helpers

    private func sharedString(_ values: [String?]) -> String? {
        let nonNil = values.compactMap { $0 }
        guard nonNil.count == values.count else { return nil }
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
        if deleteFile, let path = try await database.frameFilePath(id: id) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await database.deleteFrame(id: id)
    }
}
