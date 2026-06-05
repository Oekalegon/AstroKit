import Testing
import Foundation
@testable import AstrophotoArchiveKit

// MARK: - Minimal FITS helper

/// Creates a valid minimal FITS file (NAXIS=0, no data block) at `url`.
/// CFITSIO accepts this as a well-formed file, and `FITSHeaderReader.read` returns
/// width=0, height=0 with default metadata — sufficient for archive ingestion tests.
private func writeTinyFITS(to url: URL, imageType: String = "Light Frame") throws {
    var block = Data(repeating: 32, count: 2880)   // one header block, all spaces

    func writeCard(_ text: String, slot: Int) {
        let padded = text.padding(toLength: 80, withPad: " ", startingAt: 0)
        for (i, byte) in padded.utf8.prefix(80).enumerated() {
            block[slot * 80 + i] = byte
        }
    }

    writeCard("SIMPLE  =                    T / conforms to FITS standard", slot: 0)
    writeCard("BITPIX  =                   16 / bits per pixel", slot: 1)
    writeCard("NAXIS   =                    0 / no data array", slot: 2)
    writeCard("IMAGETYP= '\(imageType)'", slot: 3)
    writeCard("DATE-OBS= '2025-03-25T08:25:40'", slot: 4)
    writeCard("EXPTIME =                 300.0 / exposure in seconds", slot: 5)
    writeCard("END", slot: 6)

    try block.write(to: url)
}

// MARK: - Path handling tests

@Suite("Archive file-path storage and expansion")
struct ArchivePathTests {

    // MARK: - Helpers

    /// Returns a unique temp directory that is cleaned up after the test.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeConfig(root: URL) -> ArchiveConfiguration {
        ArchiveConfiguration(rootURL: root)
    }

    // MARK: - Tests

    @Test("Archive.add stores a relative path in the database")
    func addStoresRelativePath() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a tiny source FITS file outside the archive root.
        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let archive = try Archive(configuration: makeConfig(root: root))
        let (_, _) = try await archive.add(fitsFile: src)

        // Open the DB directly and inspect the stored path.
        let db = try ArchiveDatabase(url: makeConfig(root: root).databaseURL, archiveRootPath: root.path)
        let frames = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        let stored = try #require(frames.first?.filePath)

        #expect(!stored.hasPrefix("/"), "DB must store a relative path, not an absolute one")
        #expect(stored.hasSuffix(".fits"))
    }

    @Test("Archive.add returns an absolute filePath to the caller")
    func addReturnsAbsolutePath() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let archive = try Archive(configuration: makeConfig(root: root))
        let (frame, _) = try await archive.add(fitsFile: src)

        #expect(frame.filePath.hasPrefix(root.path), "Returned filePath must be absolute under the archive root")
        #expect(FileManager.default.fileExists(atPath: frame.filePath), "Returned filePath must point to the copied file")
    }

    @Test("frames(matching:) returns absolute filePaths")
    func framesMatchingReturnsAbsolutePaths() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let archive = try Archive(configuration: makeConfig(root: root))
        _ = try await archive.add(fitsFile: src)

        let frames = try await archive.frames(matching: FrameQuery())
        let path = try #require(frames.first?.filePath)
        #expect(path.hasPrefix("/"), "frames(matching:) must return an absolute path")
        #expect(path.hasPrefix(root.path))
    }

    @Test("frame(id:) returns an absolute filePath")
    func frameByIDReturnsAbsolutePath() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let archive = try Archive(configuration: makeConfig(root: root))
        let (inserted, _) = try await archive.add(fitsFile: src)

        let fetched = try await archive.frame(id: inserted.id)
        let path = try #require(fetched?.filePath)
        #expect(path.hasPrefix(root.path))
    }

    @Test("recentFrames returns absolute filePaths")
    func recentFramesReturnsAbsolutePaths() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let archive = try Archive(configuration: makeConfig(root: root))
        _ = try await archive.add(fitsFile: src)

        let frames = try await archive.recentFrames(limit: 10)
        let path = try #require(frames.first?.filePath)
        #expect(path.hasPrefix(root.path))
    }

    @Test("ArchiveDatabase normalizes absolute paths to relative on init")
    func normalizationMigratesAbsolutePaths() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = makeConfig(root: root).databaseURL
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
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = makeConfig(root: root).databaseURL
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
