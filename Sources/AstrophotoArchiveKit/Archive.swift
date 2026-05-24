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

    /// Adds a single FITS file to the archive.
    /// - Parameters:
    ///   - url: Path to the FITS file.
    ///   - copyFile: When `true` the file is copied into the archive folder hierarchy.
    /// - Returns: The frame record and `isNew: true` if it was inserted, `false` if already in archive.
    @discardableResult
    public func add(fitsFile url: URL, copyFile: Bool = false) async throws -> (frame: ArchivedFrame, isNew: Bool) {
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
        let filePath: String
        let copiedTo: URL?

        if copyFile {
            let dest = FolderOrganizer.destinationURL(
                for: meta, in: configuration.rootURL, filename: url.lastPathComponent, id: frameID
            )
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: dest)
            filePath = dest.path
            copiedTo = dest
        } else {
            filePath = url.path
            copiedTo = nil
        }

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
            addedAt: Date()
        )
        let isNew = try await database.insertFrame(frame)
        if !isNew, let copiedTo {
            try? FileManager.default.removeItem(at: copiedTo)
        }
        return (frame, isNew)
    }

    /// Adds all FITS files in a directory.
    /// - Parameters:
    ///   - directory: Directory to scan.
    ///   - recursive: Descend into subdirectories.
    ///   - copyFiles: Copy each file into the archive folder hierarchy.
    /// - Returns: A tuple of newly added frames and the count of files already in the archive.
    @discardableResult
    public func add(
        directory: URL,
        recursive: Bool = false,
        copyFiles: Bool = false
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
            let (frame, isNew) = try await add(fitsFile: fileURL, copyFile: copyFiles)
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
