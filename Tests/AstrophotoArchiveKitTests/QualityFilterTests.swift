import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("Quality metrics — storage and filtering")
struct QualityFilterTests {

    // MARK: - Helpers

    private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-\(UUID().uuidString).sqlite")
        return (try ArchiveDatabase(url: url), url)
    }

    private func makeFrame(
        starCount: Int? = nil,
        medianFWHM: Double? = nil,
        backgroundNoise: Double? = nil,
        timestamp: Double = 1_740_000_000
    ) -> ArchivedFrame {
        let date = Date(timeIntervalSince1970: timestamp)
        return ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: "M42",
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: "light",
            filter: "Hɑ",
            camera: "ZWO ASI294MC",
            focalLength: nil, pixelScale: nil,
            temperature: -10.0,
            timestamp: date,
            exposureTime: 300,
            gain: 100, offset: nil,
            width: 4096, height: 2160, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw,
            addedAt: Date(),
            fileDate: date,
            starCount: starCount,
            medianFWHM: medianFWHM,
            backgroundNoise: backgroundNoise
        )
    }

    // MARK: - Round-trip storage

    @Test func qualityMetricsRoundTrip() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame(starCount: 250, medianFWHM: 3.5, backgroundNoise: 0.0031)
        _ = try await db.insertFrame(frame)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.starCount == 250)
        #expect(retrieved?.medianFWHM == 3.5)
        #expect(retrieved?.backgroundNoise == 0.0031)
    }

    @Test func qualityMetricsDefaultToNil() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()  // no quality data
        _ = try await db.insertFrame(frame)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.starCount == nil)
        #expect(retrieved?.medianFWHM == nil)
        #expect(retrieved?.backgroundNoise == nil)
    }

    // MARK: - updateFrameQuality

    @Test func updateFrameQualityWritesAllFields() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        try await db.updateFrameQuality(id: frame.id, starCount: 180, medianFWHM: 4.2, backgroundNoise: 0.005)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.starCount == 180)
        #expect(abs((retrieved?.medianFWHM ?? 0) - 4.2) < 0.0001)
        #expect(abs((retrieved?.backgroundNoise ?? 0) - 0.005) < 0.00001)
    }

    @Test func updateFrameQualityIsAdditive() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        // Set only starCount first.
        let frame = makeFrame()
        _ = try await db.insertFrame(frame)
        try await db.updateFrameQuality(id: frame.id, starCount: 300, medianFWHM: nil, backgroundNoise: nil)

        // Then add FWHM without touching starCount.
        try await db.updateFrameQuality(id: frame.id, starCount: nil, medianFWHM: 3.8, backgroundNoise: nil)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.starCount == 300)       // preserved from first call
        #expect(abs((retrieved?.medianFWHM ?? 0) - 3.8) < 0.0001)
        #expect(retrieved?.backgroundNoise == nil)
    }

    @Test func updateFrameQualityNoOpWhenAllNil() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame(starCount: 100)
        _ = try await db.insertFrame(frame)

        // Should not throw or modify anything.
        try await db.updateFrameQuality(id: frame.id, starCount: nil, medianFWHM: nil, backgroundNoise: nil)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.starCount == 100)
    }

    // MARK: - maxFWHM filter

    @Test func maxFWHMFilterExcludesFramesAboveThreshold() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let good  = makeFrame(medianFWHM: 3.5, timestamp: 1_740_000_000)  // ≤ 5.0 → included
        let bad   = makeFrame(medianFWHM: 6.1, timestamp: 1_740_001_000)  // > 5.0 → excluded
        let noData = makeFrame(timestamp: 1_740_002_000)                  // nil   → excluded
        _ = try await db.insertFrame(good)
        _ = try await db.insertFrame(bad)
        _ = try await db.insertFrame(noData)

        var query = FrameQuery()
        query.maxFWHM = 5.0
        let results = try await db.queryFrames(query, healpixPixels: nil)

        #expect(results.count == 1)
        #expect(results[0].id == good.id)
    }

    @Test func maxFWHMFilterIncludesFrameAtExactThreshold() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let exact = makeFrame(medianFWHM: 5.0)
        _ = try await db.insertFrame(exact)

        var query = FrameQuery()
        query.maxFWHM = 5.0
        let results = try await db.queryFrames(query, healpixPixels: nil)

        #expect(results.count == 1)
    }

    // MARK: - minStarCount filter

    @Test func minStarCountFilterExcludesFramesBelowThreshold() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let rich   = makeFrame(starCount: 350, timestamp: 1_740_000_000)  // ≥ 200 → included
        let sparse = makeFrame(starCount: 80,  timestamp: 1_740_001_000)  // < 200 → excluded
        let noData = makeFrame(timestamp: 1_740_002_000)                  // nil   → excluded
        _ = try await db.insertFrame(rich)
        _ = try await db.insertFrame(sparse)
        _ = try await db.insertFrame(noData)

        var query = FrameQuery()
        query.minStarCount = 200
        let results = try await db.queryFrames(query, healpixPixels: nil)

        #expect(results.count == 1)
        #expect(results[0].id == rich.id)
    }

    // MARK: - maxBackgroundNoise filter

    @Test func maxBackgroundNoiseFilterExcludesNoisyFrames() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let quiet  = makeFrame(backgroundNoise: 0.002, timestamp: 1_740_000_000)  // ≤ 0.01 → included
        let noisy  = makeFrame(backgroundNoise: 0.05,  timestamp: 1_740_001_000)  // > 0.01 → excluded
        let noData = makeFrame(timestamp: 1_740_002_000)                          // nil    → excluded
        _ = try await db.insertFrame(quiet)
        _ = try await db.insertFrame(noisy)
        _ = try await db.insertFrame(noData)

        var query = FrameQuery()
        query.maxBackgroundNoise = 0.01
        let results = try await db.queryFrames(query, healpixPixels: nil)

        #expect(results.count == 1)
        #expect(results[0].id == quiet.id)
    }

    // MARK: - Combined filters

    @Test func combinedQualityFiltersAreConjunctive() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        // Passes all three thresholds.
        let best = makeFrame(starCount: 300, medianFWHM: 3.2, backgroundNoise: 0.003,
                             timestamp: 1_740_000_000)
        // Good FWHM and noise but too few stars.
        let lowStars = makeFrame(starCount: 50, medianFWHM: 3.2, backgroundNoise: 0.003,
                                 timestamp: 1_740_001_000)
        // Good stars and noise but bad FWHM.
        let badFWHM = makeFrame(starCount: 300, medianFWHM: 7.0, backgroundNoise: 0.003,
                                timestamp: 1_740_002_000)
        // Good stars and FWHM but noisy background.
        let noisy = makeFrame(starCount: 300, medianFWHM: 3.2, backgroundNoise: 0.08,
                              timestamp: 1_740_003_000)

        for f in [best, lowStars, badFWHM, noisy] { _ = try await db.insertFrame(f) }

        var query = FrameQuery()
        query.minStarCount       = 100
        query.maxFWHM            = 5.0
        query.maxBackgroundNoise = 0.01
        let results = try await db.queryFrames(query, healpixPixels: nil)

        #expect(results.count == 1)
        #expect(results[0].id == best.id)
    }

    @Test func qualityFiltersComposeWithOtherFilters() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        // Good quality, right object.
        let target = makeFrame(starCount: 300, medianFWHM: 3.0, backgroundNoise: 0.002,
                               timestamp: 1_740_000_000)
        // Good quality but different object — won't match the object filter.
        var otherObject = makeFrame(starCount: 300, medianFWHM: 3.0, backgroundNoise: 0.002,
                                    timestamp: 1_740_001_000)
        otherObject = ArchivedFrame(
            id: otherObject.id, filePath: otherObject.filePath,
            objectName: "M31",
            ra: 10.68, dec: 41.27, healpixPixel: nil,
            frameType: "light", filter: "Hɑ", camera: "ZWO ASI294MC",
            focalLength: nil, pixelScale: nil, temperature: -10,
            timestamp: otherObject.timestamp, exposureTime: 300,
            gain: 100, offset: nil, width: 4096, height: 2160, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw, addedAt: Date(), fileDate: otherObject.timestamp,
            starCount: 300, medianFWHM: 3.0, backgroundNoise: 0.002
        )
        _ = try await db.insertFrame(target)
        _ = try await db.insertFrame(otherObject)

        var query = FrameQuery()
        query.objectName = "M42"
        query.maxFWHM    = 5.0
        let results = try await db.queryFrames(query, healpixPixels: nil)

        #expect(results.count == 1)
        #expect(results[0].id == target.id)
    }

    // MARK: - Frames without quality data are excluded only when a filter is active

    @Test func framesWithNoQualityDataAreIncludedWhenNoFilterSet() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let withQuality    = makeFrame(starCount: 100, timestamp: 1_740_000_000)
        let withoutQuality = makeFrame(timestamp: 1_740_001_000)
        _ = try await db.insertFrame(withQuality)
        _ = try await db.insertFrame(withoutQuality)

        // No quality filters → both frames returned.
        let results = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(results.count == 2)
    }

    @Test func framesWithNoQualityDataAreExcludedWhenFilterIsSet() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let withQuality    = makeFrame(medianFWHM: 3.0, timestamp: 1_740_000_000)
        let withoutQuality = makeFrame(timestamp: 1_740_001_000)   // nil FWHM
        _ = try await db.insertFrame(withQuality)
        _ = try await db.insertFrame(withoutQuality)

        var query = FrameQuery()
        query.maxFWHM = 5.0
        let results = try await db.queryFrames(query, healpixPixels: nil)

        // Only the frame with measured FWHM passes.
        #expect(results.count == 1)
        #expect(results[0].id == withQuality.id)
    }
}
