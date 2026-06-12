import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("recentFrames limit semantics")
struct RecentFramesLimitTests {

    /// Inserts `count` frames with distinct paths, signatures, and added-at times.
    private func makeDatabase(frameCount: Int) async throws -> ArchiveDatabase {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try ArchiveDatabase(
            url: root.appendingPathComponent("archive.sqlite"),
            archiveRootPath: root.path
        )
        let base = Date(timeIntervalSince1970: 1_740_000_000)
        for i in 0..<frameCount {
            var frame = makeLimitTestFrame()
            frame.filePath = "Objects/Orion/light/frame_\(i).fits"
            frame.timestamp = base.addingTimeInterval(Double(i) * 60)
            frame.addedAt = base.addingTimeInterval(Double(i) * 60)
            // fileDate feeds the unique frame_signature; vary it or INSERT OR IGNORE drops the frame.
            frame.fileDate = base.addingTimeInterval(Double(i) * 60)
            _ = try await db.insertFrame(frame)
        }
        return db
    }

    @Test("nil limit returns all frames")
    func nilLimitReturnsAll() async throws {
        let db = try await makeDatabase(frameCount: 3)
        let frames = try await db.recentFrames(limit: nil)
        #expect(frames.count == 3)
    }

    @Test("positive limit caps the result, newest first")
    func positiveLimitCaps() async throws {
        let db = try await makeDatabase(frameCount: 3)
        let frames = try await db.recentFrames(limit: 2)
        #expect(frames.count == 2)
        #expect(frames[0].filePath.hasSuffix("frame_2.fits"), "Newest frame must come first")
    }

    @Test("explicit limit 0 returns no frames")
    func zeroLimitReturnsNone() async throws {
        let db = try await makeDatabase(frameCount: 3)
        let frames = try await db.recentFrames(limit: 0)
        #expect(frames.isEmpty)
    }

    @Test("negative limit is clamped to 0, not SQLite's unlimited")
    func negativeLimitReturnsNone() async throws {
        let db = try await makeDatabase(frameCount: 3)
        let frames = try await db.recentFrames(limit: -1)
        #expect(frames.isEmpty)
    }
}

private func makeLimitTestFrame() -> ArchivedFrame {
    let date = Date(timeIntervalSince1970: 1_740_000_000)
    return ArchivedFrame(
        id: UUID(),
        filePath: "placeholder.fits",
        objectName: "Orion",
        ra: 83.82, dec: -5.39,
        healpixPixel: nil,
        frameType: "light",
        filter: "Hɑ",
        camera: nil,
        focalLength: nil, pixelScale: nil, temperature: nil,
        timestamp: date,
        exposureTime: 300,
        gain: nil, offset: nil,
        width: 0, height: 0, bitpix: 16,
        calibrated: false, stacked: false, stretched: false,
        processingLevel: .raw,
        addedAt: date,
        fileDate: date
    )
}
