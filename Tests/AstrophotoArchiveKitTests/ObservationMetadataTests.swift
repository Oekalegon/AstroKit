import Testing
import Foundation
import AstrophotoKit
@testable import AstrophotoArchiveKit

// MARK: - Helpers

private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("obs-meta-\(UUID().uuidString).sqlite")
    return (try ArchiveDatabase(url: url, archiveRootPath: FileManager.default.temporaryDirectory.path), url)
}

private func makeFrame(
    telescope: String? = nil,
    site: String? = nil,
    camera: String? = "ZWO ASI294MC",
    objectName: String? = "M42",
    timestamp: Double = 1_740_000_000
) -> ArchivedFrame {
    let date = Date(timeIntervalSince1970: timestamp)
    return ArchivedFrame(
        id: UUID(),
        filePath: "/tmp/mock-\(UUID().uuidString).fits",
        objectName: objectName,
        ra: 83.8221, dec: -5.3911,
        healpixPixel: nil,
        frameType: "light",
        filter: "Hɑ",
        camera: camera,
        telescope: telescope,
        site: site,
        focalLength: nil, pixelScale: nil,
        temperature: -10.0,
        timestamp: date,
        exposureTime: 300,
        gain: 100, offset: nil,
        width: 4096, height: 2160, bitpix: 16,
        calibrated: false, stacked: false, stretched: false,
        processingLevel: .raw,
        addedAt: Date(),
        fileDate: date
    )
}

// MARK: - ArchivedFrame round-trip

@Suite("Observation metadata (telescope / site) — storage and retrieval")
struct ObservationMetadataTests {

    @Test("telescope and site round-trip through the database")
    func telescopeSiteRoundTrip() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame(telescope: "SkyWatcher Esprit 100ED", site: "Backyard Observatory")
        _ = try await db.insertFrame(frame)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.telescope == "SkyWatcher Esprit 100ED")
        #expect(retrieved?.site == "Backyard Observatory")
    }

    @Test("telescope and site default to nil when not set")
    func telescopeSiteDefaultNil() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()   // no telescope/site
        _ = try await db.insertFrame(frame)

        let retrieved = try await db.frameByID(frame.id)
        #expect(retrieved?.telescope == nil)
        #expect(retrieved?.site == nil)
    }

    // MARK: - FrameSet aggregation

    @Test("frameset inherits telescope when all member frames agree")
    func frameSetAggregatesTelescopeUnanimously() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let scope = "SkyWatcher Esprit 100ED"
        let f1 = makeFrame(telescope: scope, timestamp: 1_740_000_000)
        let f2 = makeFrame(telescope: scope, timestamp: 1_740_000_300)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "Test", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 2,
            objectName: "M42", filter: "Hɑ", camera: "ZWO ASI294MC",
            telescope: scope, site: nil,
            exposureTime: 300, gain: 100, offset: nil,
            width: 4096, height: 2160,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [f1.id, f2.id])

        let retrieved = try await db.frameSetByID(fs.id)
        #expect(retrieved?.telescope == scope)
        #expect(retrieved?.site == nil)
    }

    @Test("frameset telescope is nil when member frames disagree")
    func frameSetTelescopeNilWhenMixed() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(telescope: "SkyWatcher Esprit 100ED", timestamp: 1_740_000_000)
        let f2 = makeFrame(telescope: "Celestron EdgeHD 11\"", timestamp: 1_740_000_300)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "Mixed", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 2,
            objectName: "M42", filter: "Hɑ", camera: nil,
            telescope: nil, site: nil,    // mixed → nil
            exposureTime: 300, gain: nil, offset: nil,
            width: 4096, height: 2160,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [f1.id, f2.id])

        let retrieved = try await db.frameSetByID(fs.id)
        #expect(retrieved?.telescope == nil)
    }

    @Test("frameset site round-trips through the database")
    func frameSetSiteRoundTrip() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(telescope: "SkyWatcher", site: "La Palma", timestamp: 1_740_000_000)
        _ = try await db.insertFrame(f1)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "LaPalma", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Hɑ", camera: nil,
            telescope: "SkyWatcher", site: "La Palma",
            exposureTime: 300, gain: nil, offset: nil,
            width: 4096, height: 2160,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [f1.id])

        let retrieved = try await db.frameSetByID(fs.id)
        #expect(retrieved?.telescope == "SkyWatcher")
        #expect(retrieved?.site == "La Palma")
    }

    // MARK: - FrameSetQuery

    @Test("FrameSetQuery.telescope filters by telescope name")
    func queryByTelescope() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(timestamp: 1_740_000_000)
        let f2 = makeFrame(timestamp: 1_740_000_300)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)

        let fsA = ArchivedFrameSet(
            id: UUID(), name: "A", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Hɑ", camera: nil,
            telescope: "SkyWatcher Esprit 100ED", site: nil,
            exposureTime: 300, gain: nil, offset: nil, width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        let fsB = ArchivedFrameSet(
            id: UUID(), name: "B", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Hɑ", camera: nil,
            telescope: "Celestron EdgeHD 11\"", site: nil,
            exposureTime: 300, gain: nil, offset: nil, width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fsA, frameIDs: [f1.id])
        try await db.insertFrameSet(fsB, frameIDs: [f2.id])

        var query = FrameSetQuery()
        query.telescope = "SkyWatcher Esprit 100ED"
        let results = try await db.queryFrameSets(matching: query)

        #expect(results.count == 1)
        #expect(results.first?.name == "A")
    }

    @Test("FrameSetQuery.site filters by site name")
    func queryBySite() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(timestamp: 1_740_000_000)
        let f2 = makeFrame(timestamp: 1_740_000_300)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)

        let fsLP = ArchivedFrameSet(
            id: UUID(), name: "LaPalma", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Hɑ", camera: nil,
            telescope: nil, site: "La Palma",
            exposureTime: 300, gain: nil, offset: nil, width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        let fsBackyard = ArchivedFrameSet(
            id: UUID(), name: "Backyard", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Hɑ", camera: nil,
            telescope: nil, site: "Backyard",
            exposureTime: 300, gain: nil, offset: nil, width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fsLP, frameIDs: [f1.id])
        try await db.insertFrameSet(fsBackyard, frameIDs: [f2.id])

        var query = FrameSetQuery()
        query.site = "La Palma"
        let results = try await db.queryFrameSets(matching: query)

        #expect(results.count == 1)
        #expect(results.first?.name == "LaPalma")
    }
}

// MARK: - Archive.createFrameSet integration tests

/// These tests go through the full archive.add → createFrameSet path so that
/// the sharedString aggregation logic in Archive is covered end-to-end.
@Suite("Archive.createFrameSet — telescope/site aggregation")
struct ArchiveFrameSetAggregationTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a tiny FITS file with TELESCOP, OBSERVAT, and a unique OBJECT name
    /// so the archive query can target exactly these frames.
    /// `exposureTime` must be unique per call within a test — archive deduplication
    /// uses DATE + frame type + filter + exposure, so two files written in the same
    /// second with the same exposure would silently collapse to one archived entry.
    private func writeFITS(
        to url: URL,
        object: String,
        telescope: String? = nil,
        site: String? = nil,
        exposureTime: Double = 300
    ) throws {
        let pixels: [Float] = Array(repeating: 0.5, count: 4)
        try FITSTableWriter.writeResultFrame(
            pixelData: pixels, width: 2, height: 2,
            pipelineID: "test",
            imageType: "Light Frame",
            totalExposure: exposureTime,
            objectName: object,
            telescope: telescope,
            site: site,
            to: url.path
        )
    }

    @Test("createFrameSet propagates telescope when all member frames agree")
    func createFrameSetPropagatesUnanimousTelescope() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"
        let scope = "SkyWatcher Esprit 100ED"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: uniqueObject, telescope: scope, exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject, telescope: scope, exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.telescope == scope)
    }

    @Test("createFrameSet sets telescope to nil when member frames disagree")
    func createFrameSetNilsTelescopeWhenMixed() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: uniqueObject, telescope: "SkyWatcher Esprit 100ED", exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject, telescope: "Celestron EdgeHD 11", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.telescope == nil)
    }

    @Test("createFrameSet propagates site when all member frames agree")
    func createFrameSetPropagatesUnanimousSite() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: uniqueObject, site: "La Palma", exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject, site: "La Palma", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.site == "La Palma")
    }

    @Test("createFrameSet sets site to nil when member frames disagree")
    func createFrameSetNilsSiteWhenMixed() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: uniqueObject, site: "La Palma", exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject, site: "Backyard", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.site == nil)
    }

    @Test("createFrameSet propagates telescope and site together")
    func createFrameSetPropagatesTelescopeAndSiteTogether() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: uniqueObject,
                      telescope: "SkyWatcher Esprit 100ED", site: "La Palma", exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject,
                      telescope: "SkyWatcher Esprit 100ED", site: "La Palma", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.telescope == "SkyWatcher Esprit 100ED")
        #expect(fs.site == "La Palma")
    }

    @Test("createFrameSet propagates telescope when one frame lacks the header entirely")
    func createFrameSetTelescopePropagatesWhenOneFrameLacksIt() async throws {
        // "Nil does not vote" — a frame without a TELESCOP header does not block
        // the unanimous result derived from frames that do carry the header.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: uniqueObject, telescope: "SkyWatcher Esprit 100ED", exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject, telescope: nil, exposureTime: 600) // no TELESCOP
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.telescope == "SkyWatcher Esprit 100ED")
    }

    @Test("createFrameSet propagates telescope even when one frame has no site")
    func createFrameSetTelescopeWithMissingSite() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let uniqueObject = "FS-Agg-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        // Both frames same telescope, but no OBSERVAT in either
        try writeFITS(to: src1, object: uniqueObject, telescope: "SkyWatcher Esprit 100ED", exposureTime: 300)
        try writeFITS(to: src2, object: uniqueObject, telescope: "SkyWatcher Esprit 100ED", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var query = FrameQuery()
        query.objectName = uniqueObject
        let (fs, _) = try await archive.createFrameSet(name: "Test", query: query)

        #expect(fs.telescope == "SkyWatcher Esprit 100ED")
        #expect(fs.site == nil)
    }
}
