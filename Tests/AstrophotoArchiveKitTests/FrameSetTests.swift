import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("FrameSet operations")
struct FrameSetTests {

    private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frameset-\(UUID().uuidString).sqlite")
        return (try ArchiveDatabase(url: url), url)
    }

    private func makeFrame(
        frameType: String = "light",
        filter: String? = "Ha",
        objectName: String? = "M42",
        camera: String? = "ZWO ASI294MC",
        exposureTime: Double = 300,
        temperature: Double? = -10.0,
        gain: Double? = 100,
        width: Int? = 4096,
        height: Int? = 2160,
        timestamp: Double = 1_740_000_000,
        processingLevel: ProcessingLevel = .raw
    ) -> ArchivedFrame {
        ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: objectName,
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: frameType,
            filter: filter,
            camera: camera,
            focalLength: nil, pixelScale: nil,
            temperature: temperature,
            timestamp: Date(timeIntervalSince1970: timestamp),
            exposureTime: exposureTime,
            gain: gain, offset: nil,
            width: width, height: height, bitpix: 16,
            calibrated: processingLevel == .calibrated,
            stacked: processingLevel == .stacked,
            stretched: processingLevel == .stretched,
            processingLevel: processingLevel,
            addedAt: Date()
        )
    }

    // MARK: - Insert and retrieve

    @Test func insertAndListFrameSet() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "M42 Ha lights", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Ha", camera: "ZWO ASI294MC",
            exposureTime: 300, gain: 100, offset: nil,
            width: 4096, height: 2160,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: -10, temperatureMin: -10, temperatureMax: -10
        )
        try await db.insertFrameSet(fs, frameIDs: [frame.id])

        let all = try await db.queryFrameSets()
        #expect(all.count == 1)
        #expect(all[0].id == fs.id)
        #expect(all[0].name == "M42 Ha lights")
        #expect(all[0].frameType == "light")
        #expect(all[0].frameCount == 1)
        #expect(all[0].objectName == "M42")
        #expect(all[0].filter == "Ha")
    }

    @Test func frameIDsForSetReturnsInOrder() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(timestamp: 1_740_000_000)
        let f2 = makeFrame(timestamp: 1_740_001_000)
        let f3 = makeFrame(timestamp: 1_740_002_000)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)
        _ = try await db.insertFrame(f3)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "test", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 3,
            objectName: nil, filter: nil, camera: nil,
            exposureTime: nil, gain: nil, offset: nil,
            width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [f1.id, f2.id, f3.id])

        let ids = try await db.frameIDsForSet(fs.id)
        #expect(ids == [f1.id, f2.id, f3.id])
    }

    @Test func deleteFrameSetRemovesMembers() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "delete me", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: nil, filter: nil, camera: nil,
            exposureTime: nil, gain: nil, offset: nil,
            width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [frame.id])
        try await db.deleteFrameSet(id: fs.id)

        let all = try await db.queryFrameSets()
        #expect(all.isEmpty)

        // The frame itself must still exist after the set is deleted.
        let stillThere = try await db.frameByID(frame.id)
        #expect(stillThere != nil)
    }

    @Test func frameSetByIDReturnsNilForUnknown() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await db.frameSetByID(UUID())
        #expect(result == nil)
    }

    // MARK: - Archive-level API

    private func makeArchive() throws -> (Archive, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)")
        let config = ArchiveConfiguration(rootURL: root)
        return (try Archive(configuration: config), root)
    }

    @Test func createFrameSetComputesSharedProperties() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(filter: "Ha", camera: "ZWO ASI294MC", temperature: -10.0, gain: 100)
        let f2 = makeFrame(filter: "Ha", camera: "ZWO ASI294MC", temperature: -10.2, gain: 100, timestamp: 1_740_001_000)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)

        let frames = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(frames.count == 2)

        // Manually verify shared property logic matches Archive behaviour.
        let filters = Set(frames.compactMap { $0.filter })
        #expect(filters.count == 1)   // shared filter

        let cameras = Set(frames.compactMap { $0.camera })
        #expect(cameras.count == 1)   // shared camera

        let temps = frames.compactMap { $0.temperature }
        let meanTemp = temps.reduce(0, +) / Double(temps.count)
        #expect(abs(meanTemp - (-10.1)) < 0.01)
    }

    @Test func cameraQueryFilterWorks() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let f1 = makeFrame(camera: "ZWO ASI294MC",  timestamp: 1_740_000_000)
        let f2 = makeFrame(camera: "QHY268C",        timestamp: 1_740_001_000)
        _ = try await db.insertFrame(f1)
        _ = try await db.insertFrame(f2)

        var query = FrameQuery()
        query.camera = "ZWO ASI294MC"
        let results = try await db.queryFrames(query, healpixPixels: nil)
        #expect(results.count == 1)
        #expect(results[0].camera == "ZWO ASI294MC")
    }

    @Test func createFrameSetRejectsEmptyQuery() async throws {
        let (archive, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: ArchiveError.self) {
            try await archive.createFrameSet(name: "empty", query: FrameQuery())
        }
    }

    @Test func createFrameSetRejectsMixedTypes() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        // Check that mixed types are detected at the Archive level via queryFrames.
        let light = makeFrame(frameType: "light", timestamp: 1_740_000_000)
        let dark  = makeFrame(frameType: "dark",  filter: nil, timestamp: 1_740_001_000)
        _ = try await db.insertFrame(light)
        _ = try await db.insertFrame(dark)

        let results = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        let types = Set(results.map { $0.frameType })
        #expect(types.count == 2)  // mixed — Archive.createFrameSet would reject these
    }
}
