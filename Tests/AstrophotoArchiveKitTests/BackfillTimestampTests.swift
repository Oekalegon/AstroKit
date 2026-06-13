import Testing
import Foundation
import AstrophotoKit
@testable import AstrophotoArchiveKit

// MARK: - Helpers

private func writeTestFITS(dateObs: String, to url: URL) throws {
    let pixels: [Float] = Array(repeating: 0.5, count: 4)
    try FITSTableWriter.writeResultFrame(
        pixelData: pixels, width: 2, height: 2,
        pipelineID: "test",
        imageType: "Light Frame",
        dateObs: dateObs,
        to: url.path
    )
}

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

// MARK: - parseTimestamp (via FITSHeaderReader)

@Suite("parseTimestamp — FITSHeaderReader timestamp parsing")
struct ParseTimestampTests {

    @Test("Z suffix is parsed as UTC")
    func zSuffix() throws {
        let url = tempFITSURL("ts-z")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestFITS(dateObs: "2026-04-07T02:07:36Z", to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        let ts = try #require(meta.timestamp)

        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: ts)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 7)
        #expect(comps.hour == 2)
        #expect(comps.minute == 7)
        #expect(comps.second == 36)
    }

    @Test("explicit +HH:MM offset is normalised to UTC")
    func explicitOffset() throws {
        let url = tempFITSURL("ts-offset")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestFITS(dateObs: "2026-04-07T02:07:36+02:00", to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        let ts = try #require(meta.timestamp)

        // 02:07:36 +02:00 → 00:07:36 UTC
        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: ts)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 7)
        #expect(comps.hour == 0)
        #expect(comps.minute == 7)
        #expect(comps.second == 36)
    }

    @Test("2-digit subseconds without timezone are parsed as UTC with a fractional component")
    func twoDigitSubseconds() throws {
        let url = tempFITSURL("ts-2digit")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestFITS(dateObs: "2026-04-07T02:07:36.12", to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        let ts = try #require(meta.timestamp)

        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: ts)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 7)
        #expect(comps.hour == 2)
        #expect(comps.minute == 7)
        #expect(comps.second == 36)

        let base = ISO8601DateFormatter().date(from: "2026-04-07T02:07:36Z")!
        let diff = ts.timeIntervalSince(base)
        #expect(diff > 0 && diff < 1.0, "fractional part .12 must produce a positive sub-second offset")
    }

    @Test("1-digit subseconds without timezone are parsed as UTC with a fractional component")
    func oneDigitSubseconds() throws {
        let url = tempFITSURL("ts-1digit")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestFITS(dateObs: "2026-04-07T02:07:36.1", to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        let ts = try #require(meta.timestamp)

        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: ts)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 7)
        #expect(comps.hour == 2)
        #expect(comps.minute == 7)
        #expect(comps.second == 36)

        let base = ISO8601DateFormatter().date(from: "2026-04-07T02:07:36Z")!
        let diff = ts.timeIntervalSince(base)
        #expect(diff > 0 && diff < 1.0, "fractional part .1 must produce a positive sub-second offset")
    }
}

// MARK: - backfillObservationMetadata

@Suite("backfillObservationMetadata — timestamp repair")
struct BackfillTimestampTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a minimal FITS file and inserts a matching DB record with nil timestamp,
    /// simulating a frame that was archived before parseTimestamp handled the Z suffix.
    private func seedFrameWithNilTimestamp(
        root: URL,
        db: ArchiveDatabase,
        dateObs: String
    ) async throws -> ArchivedFrame {
        let fitsURL = root.appendingPathComponent("frame-\(UUID().uuidString).fits")
        let pixels: [Float] = Array(repeating: 0.5, count: 4)
        try FITSTableWriter.writeResultFrame(
            pixelData: pixels, width: 2, height: 2,
            pipelineID: "test",
            imageType: "Light Frame",
            objectName: "M42",
            telescope: "SkyWatcher",
            site: "Backyard",
            dateObs: dateObs,
            to: fitsURL.path
        )
        let frame = ArchivedFrame(
            id: UUID(),
            filePath: fitsURL.path,
            objectName: "M42",
            ra: nil, dec: nil, healpixPixel: nil,
            frameType: "light",
            filter: nil,
            camera: "ZWO ASI294MC",
            telescope: "SkyWatcher",
            site: "Backyard",
            focalLength: nil, pixelScale: nil,
            temperature: nil,
            timestamp: nil,     // nil: simulates old archive state (Z suffix not yet handled)
            exposureTime: 300.0,
            gain: nil, offset: nil,
            width: 2, height: 2, bitpix: 32,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw,
            addedAt: Date()
        )
        try await db.insertFrame(frame)
        return frame
    }

    @Test("repairs nil timestamp when FITS carries a Z-suffix DATE-OBS")
    func repairsNilTimestamp() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = ArchiveConfiguration(rootURL: root)
        let db = try ArchiveDatabase(url: config.databaseURL, archiveRootPath: root.path)
        let frame = try await seedFrameWithNilTimestamp(
            root: root, db: db, dateObs: "2026-04-07T02:07:36Z"
        )

        let archive = try Archive(configuration: config)
        let result = try await archive.backfillObservationMetadata()

        #expect(result.updated == 1)
        #expect(result.failed == 0)
        #expect(result.failedPaths.isEmpty)

        let retrieved = try await db.frameByID(frame.id)
        let ts = try #require(retrieved?.timestamp)
        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: ts)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 7)
        #expect(comps.hour == 2)
        #expect(comps.minute == 7)
        #expect(comps.second == 36)
    }

    @Test("second call returns skipped instead of updated (idempotent)")
    func idempotent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = ArchiveConfiguration(rootURL: root)
        let db = try ArchiveDatabase(url: config.databaseURL, archiveRootPath: root.path)
        _ = try await seedFrameWithNilTimestamp(root: root, db: db, dateObs: "2026-04-07T02:07:36Z")

        let archive = try Archive(configuration: config)
        let first = try await archive.backfillObservationMetadata()
        let second = try await archive.backfillObservationMetadata()

        #expect(first.updated == 1)
        #expect(second.updated == 0)
        #expect(second.skipped >= 1)
        #expect(second.failed == 0)
        #expect(second.failedPaths.isEmpty)
    }

    @Test("failed frame path is reported in failedPaths")
    func failedPathReported() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = ArchiveConfiguration(rootURL: root)
        let db = try ArchiveDatabase(url: config.databaseURL, archiveRootPath: root.path)

        // Insert a frame whose FITS file does not exist on disk.
        let missingURL = root.appendingPathComponent("ghost.fits")
        let frame = ArchivedFrame(
            id: UUID(),
            filePath: missingURL.path,
            objectName: nil,    // needsMeta = true → backfill will attempt to read the file
            ra: nil, dec: nil, healpixPixel: nil,
            frameType: "light", filter: nil, camera: nil,
            focalLength: nil, pixelScale: nil, temperature: nil,
            timestamp: nil,
            exposureTime: nil, gain: nil, offset: nil,
            width: 2, height: 2, bitpix: 32,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw, addedAt: Date()
        )
        try await db.insertFrame(frame)

        let archive = try Archive(configuration: config)
        let result = try await archive.backfillObservationMetadata()

        #expect(result.failed == 1)
        #expect(result.failedPaths.count == 1)
        #expect(result.failedPaths.first?.hasSuffix("ghost.fits") == true)
        #expect(result.updated == 0)
    }
}
