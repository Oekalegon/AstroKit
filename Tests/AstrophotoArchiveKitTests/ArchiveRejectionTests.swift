import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("Archive rejection flag")
struct ArchiveRejectionTests {

    private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rejection-\(UUID().uuidString).sqlite")
        return (try ArchiveDatabase(url: url), url)
    }

    private func makeFrame(
        frameType: String = "light",
        filter: String? = "Hɑ"
    ) -> ArchivedFrame {
        ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: "M42",
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: frameType,
            filter: filter,
            camera: nil,
            focalLength: nil, pixelScale: nil, temperature: nil,
            timestamp: Date(timeIntervalSince1970: 1_740_000_000),
            exposureTime: 300,
            gain: nil, offset: nil,
            width: 4096, height: 2160, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw,
            addedAt: Date()
        )
    }

    @Test func defaultQueryExcludesRejected() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)
        try await db.updateRejected(id: frame.id, rejected: true, reason: "bad seeing")

        let results = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(results.isEmpty)
    }

    @Test func includeAllReturnsRejected() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)
        try await db.updateRejected(id: frame.id, rejected: true, reason: nil)

        var query = FrameQuery()
        query.rejectionFilter = .includeAll
        let results = try await db.queryFrames(query, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results[0].rejected == true)
    }

    @Test func onlyRejectedFilter() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let bad = makeFrame()
        var good = makeFrame()
        good = ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: "M42",
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: "light",
            filter: "Hɑ",
            camera: nil,
            focalLength: nil, pixelScale: nil, temperature: nil,
            timestamp: Date(timeIntervalSince1970: 1_740_001_000),
            exposureTime: 300,
            gain: nil, offset: nil,
            width: 4096, height: 2160, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw,
            addedAt: Date()
        )
        _ = try await db.insertFrame(bad)
        _ = try await db.insertFrame(good)
        try await db.updateRejected(id: bad.id, rejected: true, reason: "trailed stars")

        var query = FrameQuery()
        query.rejectionFilter = .onlyRejected
        let results = try await db.queryFrames(query, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results[0].id == bad.id)
        #expect(results[0].rejectedReason == "trailed stars")
    }

    @Test func unrejectRoundTrip() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)
        try await db.updateRejected(id: frame.id, rejected: true, reason: "test")
        try await db.updateRejected(id: frame.id, rejected: false, reason: nil)

        let results = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results[0].rejected == false)
        #expect(results[0].rejectedReason == nil)
    }

    @Test func nonRejectedFrameAppearsInDefaultQuery() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let bad = makeFrame()
        let good = ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: "M42",
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: "light",
            filter: "Hɑ",
            camera: nil,
            focalLength: nil, pixelScale: nil, temperature: nil,
            timestamp: Date(timeIntervalSince1970: 1_740_002_000),
            exposureTime: 300,
            gain: nil, offset: nil,
            width: 4096, height: 2160, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw,
            addedAt: Date()
        )
        _ = try await db.insertFrame(bad)
        _ = try await db.insertFrame(good)
        try await db.updateRejected(id: bad.id, rejected: true, reason: nil)

        let results = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results[0].id == good.id)
        #expect(results[0].rejected == false)
    }
}
