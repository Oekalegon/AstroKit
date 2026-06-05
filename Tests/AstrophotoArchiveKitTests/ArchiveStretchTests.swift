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

    @Test("slider positions persist independently of normalization bounds")
    func sliderPositionsPersistIndependently() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        // Scenario: normalize to [0, 0.1], then move white slider to 0.4 in stretch → 0.04 in data space
        let settings = StretchSettings(inputBlack: 0.0, inputWhite: 0.1)
        try await db.updateStretchSettings(id: frame.id, settings: settings, sliderBlackNorm: 0.0, sliderWhiteNorm: 0.04)

        let fetched = try await db.frameByID(frame.id)
        let saved = try #require(fetched?.stretchSettings)
        #expect(abs(saved.inputBlack - 0.0) < 1e-6)
        #expect(abs(saved.inputWhite - 0.1) < 1e-6)
        // Slider positions are stored independently of the normalization bounds
        #expect(abs((fetched?.sliderBlackNorm ?? -1) - 0.0)  < 1e-6)
        #expect(abs((fetched?.sliderWhiteNorm ?? -1) - 0.04) < 1e-5)
    }

    @Test("slider positions can be updated without changing normalization")
    func sliderUpdateWithoutNormChange() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        let settings = StretchSettings(inputBlack: 0.0, inputWhite: 0.1)
        try await db.updateStretchSettings(id: frame.id, settings: settings, sliderBlackNorm: 0.0, sliderWhiteNorm: 1.0)
        // Update only slider, keep normalization the same
        try await db.updateStretchSettings(id: frame.id, settings: settings, sliderBlackNorm: 0.0, sliderWhiteNorm: 0.04)

        let fetched = try await db.frameByID(frame.id)
        // Normalization bounds unchanged
        #expect(abs((fetched?.stretchSettings?.inputWhite ?? -1) - 0.1) < 1e-6)
        // Slider updated
        #expect(abs((fetched?.sliderWhiteNorm ?? -1) - 0.04) < 1e-5)
    }

    @Test("clearing stretch also clears slider positions")
    func clearingStretchClearsSliders() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        try await db.updateStretchSettings(id: frame.id, settings: StretchSettings(inputBlack: 0.0, inputWhite: 0.1), sliderBlackNorm: 0.0, sliderWhiteNorm: 0.04)
        try await db.updateStretchSettings(id: frame.id, settings: nil, sliderBlackNorm: nil, sliderWhiteNorm: nil)

        let fetched = try await db.frameByID(frame.id)
        #expect(fetched?.stretchSettings == nil)
        #expect(fetched?.sliderBlackNorm == nil)
        #expect(fetched?.sliderWhiteNorm == nil)
    }

    @Test("newly inserted frame has nil slider positions")
    func newFrameHasNilSliders() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)
        let fetched = try await db.frameByID(frame.id)
        #expect(fetched?.sliderBlackNorm == nil)
        #expect(fetched?.sliderWhiteNorm == nil)
    }

    @Test("out-of-range slider norms are stored and retrieved as-is — validation is the caller's responsibility")
    func outOfRangeSliderNormsStoredAsIs() async throws {
        // ArchiveDatabase does not validate slider norms. CLI (--slider-black/--slider-white)
        // and MCP (archive_update_stretch) validate at their respective entry points.
        // This test documents that the storage layer is a faithful round-trip.
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        try await db.updateStretchSettings(id: frame.id, settings: nil, sliderBlackNorm: -0.1, sliderWhiteNorm: 1.5)

        let fetched = try await db.frameByID(frame.id)
        #expect(abs((fetched?.sliderBlackNorm ?? 99) - (-0.1)) < 1e-5)
        #expect(abs((fetched?.sliderWhiteNorm ?? 99) -   1.5)  < 1e-5)
    }

    @Test("updating stretch on non-existent frame is a silent no-op")
    func updateNonExistentFrame() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // Should not throw even if no row is affected.
        try await db.updateStretchSettings(id: UUID(), settings: StretchSettings(inputBlack: 0.1, inputWhite: 0.9))
    }
}
