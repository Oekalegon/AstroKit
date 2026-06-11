import Testing
import Foundation
import SQLite3
import AstrophotoKit
@testable import AstrophotoArchiveKit

// MARK: - Header derivation

@Suite("FITSHeaderReader — pixel scale derivation from optics keywords")
struct PixelScaleDerivationTests {

    private func parse(_ headers: [String: FITSHeaderValue]) -> FrameArchiveMetadata {
        FITSHeaderReader.parse(headers: headers, width: 2, height: 2, bitpix: 16)
    }

    @Test("derives pixel scale from XPIXSZ and FOCALLEN when no scale keyword exists")
    func derivesFromOptics() throws {
        let meta = parse([
            "IMAGETYP": .string("Light Frame"),
            "XPIXSZ":   .floatingPoint(3.76),
            "FOCALLEN": .floatingPoint(530),
        ])
        let scale = try #require(meta.pixelScale)
        #expect(abs(scale - 206.2648 * 3.76 / 530) < 1e-4)
    }

    @Test("XBINNING multiplies the derived scale")
    func binningMultiplies() throws {
        let meta = parse([
            "IMAGETYP": .string("Light Frame"),
            "XPIXSZ":   .floatingPoint(3.76),
            "XBINNING": .integer(2),
            "FOCALLEN": .floatingPoint(530),
        ])
        let scale = try #require(meta.pixelScale)
        #expect(abs(scale - 2 * 206.2648 * 3.76 / 530) < 1e-4)
    }

    @Test("an explicit PIXSCALE keyword wins over derivation")
    func explicitScaleWins() throws {
        let meta = parse([
            "IMAGETYP": .string("Light Frame"),
            "PIXSCALE": .floatingPoint(0.55),
            "XPIXSZ":   .floatingPoint(3.76),
            "FOCALLEN": .floatingPoint(530),
        ])
        #expect(meta.pixelScale == 0.55)
    }

    @Test("no FOCALLEN means no derived scale")
    func missingFocalLength() {
        let meta = parse([
            "IMAGETYP": .string("Light Frame"),
            "XPIXSZ":   .floatingPoint(3.76),
        ])
        #expect(meta.pixelScale == nil)
    }
}

// MARK: - Archive.setPixelScale

@Suite("Archive.setPixelScale — bulk equipment update")
struct SetPixelScaleTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pxscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Exposure times must be unique per call within a test — deduplication uses
    /// DATE + frame type + filter + exposure (see ObservationMetadataTests).
    private func writeFITS(
        to url: URL,
        object: String,
        telescope: String? = nil,
        camera: String? = nil,
        pixelScale: Double? = nil,
        exposureTime: Double = 300
    ) throws {
        let pixels: [Float] = Array(repeating: 0.5, count: 4)
        try FITSTableWriter.writeResultFrame(
            pixelData: pixels, width: 2, height: 2,
            pipelineID: "test",
            imageType: "Light Frame",
            totalExposure: exposureTime,
            objectName: object,
            camera: camera,
            telescope: telescope,
            pixelScale: pixelScale,
            to: url.path
        )
    }

    /// Executes SQL against the archive database with a direct SQLite connection.
    private func exec(_ sql: String, on url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) } ?? ""
        sqlite3_free(err)
        try #require(rc == SQLITE_OK, "SQL failed: \(message)")
    }

    @Test("fills nil pixel scale on frames matching the telescope, leaves others untouched")
    func fillsMatchingTelescope() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let object = "PX-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: object, telescope: "SPA-1-CMOS", exposureTime: 300)
        try writeFITS(to: src2, object: object, telescope: "Other Scope", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        let (frames, _) = try await archive.setPixelScale(0.41, telescope: "SPA-1-CMOS")
        #expect(frames == 1)

        var q = FrameQuery()
        q.objectName = object
        q.rejectionFilter = .includeAll
        let all = try await archive.frames(matching: q)
        #expect(all.first { $0.telescope == "SPA-1-CMOS" }?.pixelScale == 0.41)
        #expect(all.first { $0.telescope == "Other Scope" }?.pixelScale == nil)
    }

    @Test("existing pixel scales are preserved unless overwrite is requested")
    func overwriteSemantics() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let object = "PX-\(UUID().uuidString)"

        let src = root.appendingPathComponent("f1.fits")
        try writeFITS(to: src, object: object, telescope: "SPA-1-CMOS", pixelScale: 0.7, exposureTime: 300)
        _ = try await archive.add(fitsFile: src)

        var q = FrameQuery()
        q.objectName = object
        q.rejectionFilter = .includeAll

        let (filled, _) = try await archive.setPixelScale(0.41, telescope: "SPA-1-CMOS")
        #expect(filled == 0)
        let preserved = try await archive.frames(matching: q).first?.pixelScale
        #expect(preserved == 0.7)

        let (overwritten, _) = try await archive.setPixelScale(0.41, telescope: "SPA-1-CMOS", overwrite: true)
        #expect(overwritten == 1)
        let replaced = try await archive.frames(matching: q).first?.pixelScale
        #expect(replaced == 0.41)
    }

    @Test("matching by camera works like matching by telescope")
    func matchByCamera() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let object = "PX-\(UUID().uuidString)"

        let src = root.appendingPathComponent("f1.fits")
        try writeFITS(to: src, object: object, camera: "QHY600M", exposureTime: 300)
        _ = try await archive.add(fitsFile: src)

        let (frames, _) = try await archive.setPixelScale(0.41, camera: "QHY600M")
        #expect(frames == 1)
    }

    @Test("framesets matching the telescope are updated together with their frames")
    func updatesFrameSets() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let object = "PX-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: object, telescope: "SPA-1-CMOS", exposureTime: 300)
        try writeFITS(to: src2, object: object, telescope: "SPA-1-CMOS", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var q = FrameQuery()
        q.objectName = object
        let (fs, _) = try await archive.createFrameSet(name: "Set", query: q)
        #expect(fs.pixelScale == nil)

        let (frames, frameSets) = try await archive.setPixelScale(0.41, telescope: "SPA-1-CMOS")
        #expect(frames == 2)
        #expect(frameSets == 1)
        let updated = try await archive.frameSet(id: fs.id)?.pixelScale
        #expect(updated == 0.41)
    }

    @Test("framesets without equipment fields are filled from unanimous member frames")
    func propagatesToFrameSetsViaMembers() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ArchiveConfiguration(rootURL: root)
        let archive = try Archive(configuration: config)
        let object = "PX-\(UUID().uuidString)"

        let src1 = root.appendingPathComponent("f1.fits")
        let src2 = root.appendingPathComponent("f2.fits")
        try writeFITS(to: src1, object: object, telescope: "SPA-1-CMOS", exposureTime: 300)
        try writeFITS(to: src2, object: object, telescope: "SPA-1-CMOS", exposureTime: 600)
        _ = try await archive.add(fitsFile: src1)
        _ = try await archive.add(fitsFile: src2)

        var q = FrameQuery()
        q.objectName = object
        let (fs, _) = try await archive.createFrameSet(name: "Set", query: q)

        // Simulate a frameset created before equipment aggregation existed:
        // it cannot be matched by telescope/camera, only via its members.
        try exec(
            "UPDATE frame_sets SET telescope = NULL, camera = NULL WHERE id = '\(fs.id.uuidString)'",
            on: config.databaseURL
        )

        let (frames, frameSets) = try await archive.setPixelScale(0.41, telescope: "SPA-1-CMOS")
        #expect(frames == 2)
        #expect(frameSets == 1)
        let propagated = try await archive.frameSet(id: fs.id)?.pixelScale
        #expect(propagated == 0.41)
    }

    @Test("rejects calls without a telescope or camera filter")
    func requiresEquipmentFilter() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))

        await #expect(throws: ArchiveError.self) {
            _ = try await archive.setPixelScale(0.41)
        }
        await #expect(throws: ArchiveError.self) {
            _ = try await archive.setPixelScale(-1, telescope: "SPA-1-CMOS")
        }
    }
}
