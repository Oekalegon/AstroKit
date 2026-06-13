import Testing
import Foundation
@testable import AstrophotoArchiveKit

// MARK: - Path handling tests

@Suite("Archive file-path storage and expansion")
struct ArchivePathTests {

    // MARK: - Tests

    @Test("Archive.add stores a relative path in the database")
    func addStoresRelativePath() async throws {
        let (archive, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a tiny source FITS file outside the archive root.
        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let (_, _) = try await archive.add(fitsFile: src)

        // Open the DB directly and inspect the stored path.
        let db = try ArchiveDatabase(
            url: ArchiveConfiguration(rootURL: root).databaseURL,
            archiveRootPath: root.path
        )
        let frames = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        let stored = try #require(frames.first?.filePath)

        #expect(!stored.hasPrefix("/"), "DB must store a relative path, not an absolute one")
        #expect(stored.hasSuffix(".fits"))
    }

    @Test("Archive.add returns an absolute filePath to the caller")
    func addReturnsAbsolutePath() async throws {
        let (archive, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let (frame, _) = try await archive.add(fitsFile: src)

        #expect(frame.filePath.hasPrefix(root.path), "Returned filePath must be absolute under the archive root")
        #expect(FileManager.default.fileExists(atPath: frame.filePath), "Returned filePath must point to the copied file")
    }

    @Test("frames(matching:) returns absolute filePaths")
    func framesMatchingReturnsAbsolutePaths() async throws {
        let (archive, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)
        _ = try await archive.add(fitsFile: src)

        let frames = try await archive.frames(matching: FrameQuery())
        let path = try #require(frames.first?.filePath)
        #expect(path.hasPrefix("/"), "frames(matching:) must return an absolute path")
        #expect(path.hasPrefix(root.path))
    }

    @Test("frame(id:) returns an absolute filePath")
    func frameByIDReturnsAbsolutePath() async throws {
        let (archive, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)
        let (inserted, _) = try await archive.add(fitsFile: src)

        let fetched = try await archive.frame(id: inserted.id)
        let path = try #require(fetched?.filePath)
        #expect(path.hasPrefix(root.path))
    }

    @Test("recentFrames returns absolute filePaths")
    func recentFramesReturnsAbsolutePaths() async throws {
        let (archive, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)
        _ = try await archive.add(fitsFile: src)

        let frames = try await archive.recentFrames(limit: 10)
        let path = try #require(frames.first?.filePath)
        #expect(path.hasPrefix(root.path))
    }

    @Test("ArchiveDatabase normalizes absolute paths to relative on init")
    func normalizationMigratesAbsolutePaths() async throws {
        let (_, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = ArchiveConfiguration(rootURL: root).databaseURL
        let absolutePath = root.path + "/Objects/Orion/2025-01-01/light/frame.fits"

        // Insert a frame with an absolute path using a non-matching root,
        // simulating a legacy DB created before the relative-path change.
        let legacyDB = try ArchiveDatabase(url: dbURL, archiveRootPath: "/nonexistent/legacy")
        var frame = makePathTestFrame()
        frame.filePath = absolutePath
        _ = try await legacyDB.insertFrame(frame)

        // Re-open with the real archive root — normalization fires in init.
        let normalizedDB = try ArchiveDatabase(url: dbURL, archiveRootPath: root.path)
        let frames = try await normalizedDB.queryFrames(FrameQuery(), healpixPixels: nil)
        let stored = try #require(frames.first?.filePath)

        #expect(!stored.hasPrefix("/"), "After normalization the stored path must be relative")
        #expect(stored == "Objects/Orion/2025-01-01/light/frame.fits")
    }

    @Test("Normalization does not modify paths that are already relative")
    func normalizationIsIdempotentOnRelativePaths() async throws {
        let (_, root) = try makeTempArchive(prefix: "archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = ArchiveConfiguration(rootURL: root).databaseURL
        let relativePath = "Objects/Orion/2025-01-01/light/frame.fits"

        let db = try ArchiveDatabase(url: dbURL, archiveRootPath: root.path)
        var frame = makePathTestFrame()
        frame.filePath = relativePath
        _ = try await db.insertFrame(frame)

        // Re-open to run normalization a second time.
        let db2 = try ArchiveDatabase(url: dbURL, archiveRootPath: root.path)
        let frames = try await db2.queryFrames(FrameQuery(), healpixPixels: nil)
        let stored = try #require(frames.first?.filePath)

        #expect(stored == relativePath, "Relative paths must not be modified by normalization")
    }
}

// MARK: - Test frame factory

private let pathTestDate = Date(timeIntervalSince1970: 1_740_000_000)

private func makePathTestFrame() -> ArchivedFrame {
    ArchivedFrame(
        id: UUID(),
        filePath: "placeholder.fits",
        objectName: "Orion",
        ra: 83.82, dec: -5.39,
        healpixPixel: nil,
        frameType: "light",
        filter: "Hɑ",
        camera: nil,
        focalLength: nil, pixelScale: nil, temperature: nil,
        timestamp: pathTestDate,
        exposureTime: 300,
        gain: nil, offset: nil,
        width: 0, height: 0, bitpix: 16,
        calibrated: false, stacked: false, stretched: false,
        processingLevel: .raw,
        addedAt: Date(),
        fileDate: pathTestDate
    )
}
