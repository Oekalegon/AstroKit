import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("FrameQuery — filter field coverage (ASTR-69)")
struct FrameQueryFilterTests {

    // MARK: - Test infrastructure

    private func makeDB() throws -> (ArchiveDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fq-\(UUID().uuidString).sqlite")
        return (try ArchiveDatabase(url: url, archiveRootPath: FileManager.default.temporaryDirectory.path), url)
    }

    /// Builds a minimal ArchivedFrame for round-trip filter tests.
    /// `seed` drives a unique fileDate/timestamp so every call produces a distinct frame_signature.
    private func frame(
        seed: Int,
        frameType: String = "light",
        exposureTime: Double = 300,
        focalLength: Double? = nil,
        aperture: Double? = nil,
        pixelSizeUm: Double? = nil,
        binning: Int? = nil,
        gain: Double? = 100,
        offset: Double? = 10,
        pixelScale: Double? = nil,
        egain: Double? = nil,
        positionAngle: Double? = nil,
        width: Int? = 4096,
        height: Int? = 3000,
        bitpix: Int? = 16,
        addedAt: Date = Date(),
        sunAltitude: Double? = nil,
        moonSeparation: Double? = nil,
        moonIllumination: Double? = nil
    ) -> ArchivedFrame {
        let t = Date(timeIntervalSince1970: 1_740_000_000 + Double(seed) * 3600)
        return ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/fq-test-\(UUID().uuidString).fits",
            objectName: nil,
            ra: nil, dec: nil,
            healpixPixel: nil,
            frameType: frameType,
            filter: nil,
            camera: "Test Camera",
            focalLength: focalLength,
            aperture: aperture,
            pixelSizeUm: pixelSizeUm,
            binning: binning,
            pixelScale: pixelScale,
            temperature: -20.0,
            timestamp: t,
            exposureTime: exposureTime,
            gain: gain,
            offset: offset,
            width: width,
            height: height,
            bitpix: bitpix,
            calibrated: false,
            stacked: false,
            stretched: false,
            processingLevel: .raw,
            addedAt: addedAt,
            positionAngle: positionAngle,
            fileDate: t,
            egain: egain,
            sunAltitude: sunAltitude,
            moonSeparation: moonSeparation,
            moonIllumination: moonIllumination
        )
    }

    // MARK: - Optics / sensor range filters

    @Test("focalLengthRange includes in-range frames and excludes out-of-range")
    func focalLengthRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, focalLength: 500))
        _ = try await db.insertFrame(frame(seed: 1, focalLength: 1000))

        var q = FrameQuery(); q.focalLengthRange = 400...600
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.focalLength == 500)
    }

    @Test("apertureRange includes in-range frames and excludes out-of-range")
    func apertureRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, aperture: 100))
        _ = try await db.insertFrame(frame(seed: 1, aperture: 200))

        var q = FrameQuery(); q.apertureRange = 80...150
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.aperture == 100)
    }

    @Test("pixelSizeRange includes in-range frames and excludes out-of-range")
    func pixelSizeRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, pixelSizeUm: 3.76))
        _ = try await db.insertFrame(frame(seed: 1, pixelSizeUm: 5.94))

        var q = FrameQuery(); q.pixelSizeRange = 3.0...4.5
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.pixelSizeUm == 3.76)
    }

    @Test("pixelScaleRange includes in-range frames and excludes out-of-range")
    func pixelScaleRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, pixelScale: 0.5))
        _ = try await db.insertFrame(frame(seed: 1, pixelScale: 2.0))

        var q = FrameQuery(); q.pixelScaleRange = 0.3...1.0
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.pixelScale == 0.5)
    }

    // MARK: - Exact match filters

    @Test("binning exact match returns only frames with the specified binning factor")
    func binningExactMatch() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, binning: 1))
        _ = try await db.insertFrame(frame(seed: 1, binning: 2))

        var q = FrameQuery(); q.binning = 1
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.binning == 1)
    }

    @Test("gain exact match returns only frames with the specified GAIN value")
    func gainExactMatch() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, gain: 100))
        _ = try await db.insertFrame(frame(seed: 1, gain: 200))

        var q = FrameQuery(); q.gain = 100
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.gain == 100)
    }

    @Test("offset exact match returns only frames with the specified OFFSET value")
    func offsetExactMatch() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, offset: 10))
        _ = try await db.insertFrame(frame(seed: 1, offset: 50))

        var q = FrameQuery(); q.offset = 10
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.offset == 10)
    }

    @Test("bitpix exact match returns only frames with the specified FITS BITPIX")
    func bitpixExactMatch() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, bitpix: 16))
        _ = try await db.insertFrame(frame(seed: 1, bitpix: -32))

        var q = FrameQuery(); q.bitpix = 16
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.bitpix == 16)
    }

    // MARK: - Exposure time range

    @Test("exposureTimeRange includes in-range frames and excludes out-of-range")
    func exposureTimeRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, exposureTime: 300))
        _ = try await db.insertFrame(frame(seed: 1, exposureTime: 600))

        var q = FrameQuery(); q.exposureTimeRange = 60...400
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.exposureTime == 300)
    }

    // MARK: - Image dimension filters

    @Test("widthRange includes in-range frames and excludes out-of-range")
    func widthRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, width: 4096))
        _ = try await db.insertFrame(frame(seed: 1, width: 6248))

        var q = FrameQuery(); q.widthRange = 3000...5000
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.width == 4096)
    }

    @Test("heightRange includes in-range frames and excludes out-of-range")
    func heightRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, height: 3000))
        _ = try await db.insertFrame(frame(seed: 1, height: 4176))

        var q = FrameQuery(); q.heightRange = 2000...3500
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.height == 3000)
    }

    // MARK: - Sensor output filters

    @Test("egainRange includes in-range frames and excludes out-of-range")
    func egainRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, egain: 0.6))
        _ = try await db.insertFrame(frame(seed: 1, egain: 2.0))

        var q = FrameQuery(); q.egainRange = 0.5...1.0
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.egain == 0.6)
    }

    @Test("positionAngleRange includes in-range frames and excludes out-of-range")
    func positionAngleRange() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, positionAngle: 90))
        _ = try await db.insertFrame(frame(seed: 1, positionAngle: 270))

        var q = FrameQuery(); q.positionAngleRange = 0...180
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.positionAngle == 90)
    }

    // MARK: - Archive timestamp filters

    @Test("addedAfter excludes frames archived before the cutoff")
    func addedAfter() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let early  = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14
        let recent = Date(timeIntervalSince1970: 1_740_000_000)  // 2025-02-19
        let cutoff = Date(timeIntervalSince1970: 1_720_000_000)  // 2024-07-04

        _ = try await db.insertFrame(frame(seed: 0, addedAt: early))
        _ = try await db.insertFrame(frame(seed: 1, addedAt: recent))

        var q = FrameQuery(); q.addedAfter = cutoff
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        let addedAt = try #require(results.first?.addedAt)
        #expect(addedAt.timeIntervalSince1970 > cutoff.timeIntervalSince1970)
    }

    @Test("addedBefore excludes frames archived after the cutoff")
    func addedBefore() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let early  = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14
        let recent = Date(timeIntervalSince1970: 1_740_000_000)  // 2025-02-19
        let cutoff = Date(timeIntervalSince1970: 1_720_000_000)  // 2024-07-04

        _ = try await db.insertFrame(frame(seed: 0, addedAt: early))
        _ = try await db.insertFrame(frame(seed: 1, addedAt: recent))

        var q = FrameQuery(); q.addedBefore = cutoff
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        let addedAt = try #require(results.first?.addedAt)
        #expect(addedAt.timeIntervalSince1970 < cutoff.timeIntervalSince1970)
    }

    // MARK: - Celestial context filters

    @Test("maxSunAltitude excludes frames taken when the Sun was above the threshold")
    func maxSunAltitude() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, sunAltitude: -25))  // deep night — in-range
        _ = try await db.insertFrame(frame(seed: 1, sunAltitude: -5))   // twilight — excluded

        var q = FrameQuery(); q.maxSunAltitude = -18  // astronomical night
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.sunAltitude == -25)
    }

    @Test("minMoonSeparation excludes frames where the Moon was too close to the target field")
    func minMoonSeparation() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, moonSeparation: 60))  // clear — in-range
        _ = try await db.insertFrame(frame(seed: 1, moonSeparation: 15))  // too close — excluded

        var q = FrameQuery(); q.minMoonSeparation = 30
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.moonSeparation == 60)
    }

    @Test("maxMoonIllumination excludes frames taken under a bright moon")
    func maxMoonIllumination() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, moonIllumination: 0.1))  // dark moon — in-range
        _ = try await db.insertFrame(frame(seed: 1, moonIllumination: 0.9))  // bright moon — excluded

        var q = FrameQuery(); q.maxMoonIllumination = 0.3
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.moonIllumination == 0.1)
    }

    // MARK: - NULL exclusion semantics

    @Test("range filters implicitly exclude frames where the column is NULL")
    func rangeFilterExcludesNullRows() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.insertFrame(frame(seed: 0, focalLength: nil))   // no focal_length — excluded
        _ = try await db.insertFrame(frame(seed: 1, focalLength: 800))   // in-range

        var q = FrameQuery(); q.focalLengthRange = 500...1000
        let results = try await db.queryFrames(q, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results.first?.focalLength == 800)
    }
}
