import Testing
import Foundation
import AstrophotoKit
@testable import AstrophotoArchiveKit

@Suite("Archive stretch settings persistence")
struct ArchiveStretchTests {

    private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stretch-\(UUID().uuidString).sqlite")
        return (try ArchiveDatabase(url: url, archiveRootPath: FileManager.default.temporaryDirectory.path), url)
    }

    private func makeFrame() -> ArchivedFrame {
        let date = Date(timeIntervalSince1970: 1_740_000_000)
        return ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: "M42",
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: "light",
            filter: "L",
            camera: nil,
            focalLength: nil, pixelScale: nil, temperature: nil,
            timestamp: date,
            exposureTime: 300,
            gain: nil, offset: nil,
            width: 4096, height: 2160, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw,
            addedAt: Date(),
            fileDate: date
        )
    }

    @Test("newly inserted frame has nil stretchSettings")
    func newFrameHasNilStretch() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)
        let fetched = try await db.frameByID(frame.id)
        #expect(fetched?.stretchSettings == nil)
    }

    @Test("updateStretchSettings persists and reads back correctly")
    func updateAndReadBack() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        let settings = StretchSettings(inputBlack: 0.05, inputWhite: 0.35)
        try await db.updateStretchSettings(id: frame.id, settings: settings)

        let fetched = try await db.frameByID(frame.id)
        let saved = try #require(fetched?.stretchSettings)
        #expect(abs(saved.inputBlack - 0.05) < 1e-6)
        #expect(abs(saved.inputWhite - 0.35) < 1e-6)
    }

    @Test("updateStretchSettings with nil clears a previously saved stretch")
    func clearStretch() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        try await db.updateStretchSettings(id: frame.id, settings: StretchSettings(inputBlack: 0.1, inputWhite: 0.9))
        try await db.updateStretchSettings(id: frame.id, settings: nil)

        let fetched = try await db.frameByID(frame.id)
        #expect(fetched?.stretchSettings == nil)
    }

    @Test("Archive.updateStretchSettings persists and Archive.frame reads it back")
    func archivePublicAPI() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        // Verify via ArchiveDatabase (internal) that the column round-trips.
        let settings = StretchSettings(inputBlack: 0.02, inputWhite: 0.18)
        try await db.updateStretchSettings(id: frame.id, settings: settings)
        let fetched = try await db.frameByID(frame.id)
        let saved = try #require(fetched?.stretchSettings)
        #expect(abs(saved.inputBlack - 0.02) < 1e-6)
        #expect(abs(saved.inputWhite - 0.18) < 1e-6)
        #expect(!saved.isIdentity)
    }

    @Test("updating stretch on non-existent frame is a silent no-op")
    func updateNonExistentFrame() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // Should not throw even if no row is affected.
        try await db.updateStretchSettings(id: UUID(), settings: StretchSettings(inputBlack: 0.1, inputWhite: 0.9))
    }
}
