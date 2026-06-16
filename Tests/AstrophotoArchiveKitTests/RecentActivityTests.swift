import Testing
import Foundation
@testable import AstrophotoArchiveKit

// MARK: - Helpers

/// Returns a minimal raw light frame for direct DB insertion.
/// `addedAt` defaults to `timestamp` so tests with fixed timestamps produce predictable sort order.
private func makeBareFrame(
    frameType: String = "light",
    timestamp: Date,
    processingLevel: ProcessingLevel = .raw,
    addedAt: Date? = nil,
    processingRunID: UUID? = nil,
    sessionID: UUID? = nil
) -> ArchivedFrame {
    ArchivedFrame(
        id: UUID(),
        filePath: "/tmp/test-\(UUID().uuidString).fits",
        objectName: nil, ra: nil, dec: nil, healpixPixel: nil,
        frameType: frameType,
        filter: nil, camera: nil,
        focalLength: nil, pixelScale: nil, temperature: nil,
        timestamp: timestamp,
        exposureTime: 300,
        gain: nil, offset: nil,
        width: nil, height: nil, bitpix: 16,
        calibrated: processingLevel == .calibrated,
        stacked:    processingLevel == .stacked,
        stretched:  processingLevel == .stretched,
        processingLevel: processingLevel,
        addedAt: addedAt ?? timestamp,
        processingRunID: processingRunID,
        sessionID: sessionID,
        fileDate: timestamp
    )
}

// MARK: - Suite

@Suite("Archive.recentActivity — bucketing, deduplication, and limit")
struct RecentActivityTests {

    // MARK: Session grouping

    @Test("two raw frames for the same session produce a single .session entry")
    func sessionGroupingDeduplication() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-sess")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let ts1 = ISO8601DateFormatter().date(from: "2026-04-06T20:17:00Z")!
        let ts2 = ts1.addingTimeInterval(600)

        // findOrCreateSession increments frame_count each call at the same site.
        let sid = try await db.findOrCreateSession(timestamp: ts1, latDeg: 59.93, lonDeg: 10.68)
        _ = try await db.findOrCreateSession(timestamp: ts2, latDeg: 59.93, lonDeg: 10.68)

        _ = try await db.insertFrame(makeBareFrame(timestamp: ts1, sessionID: sid), deduplicate: false)
        _ = try await db.insertFrame(makeBareFrame(timestamp: ts2, sessionID: sid), deduplicate: false)

        let activity = try await archive.recentActivity(limit: 10)
        let sessions = activity.compactMap {
            if case .session(let s, _) = $0 { return s } else { return nil }
        }

        #expect(sessions.count == 1, "Two frames in the same session should produce exactly one .session entry")
        #expect(sessions.first?.frameCount == 2)
    }

    // MARK: Date grouping

    @Test("raw frames without GPS on the same UTC date produce a single .dateGroup")
    func sameUTCDateGroupedTogether() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-same-date")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let fmt = ISO8601DateFormatter()
        _ = try await db.insertFrame(
            makeBareFrame(timestamp: fmt.date(from: "2026-04-06T20:00:00Z")!), deduplicate: false)
        _ = try await db.insertFrame(
            makeBareFrame(timestamp: fmt.date(from: "2026-04-06T21:30:00Z")!), deduplicate: false)

        let activity = try await archive.recentActivity(limit: 10)
        let groups = activity.compactMap { entry -> (key: String, count: Int)? in
            if case .dateGroup(_, let k, _, let c) = entry { return (k, c) } else { return nil }
        }

        let group = try #require(groups.first, "Two frames on the same UTC date should produce one .dateGroup")
        #expect(groups.count == 1)
        #expect(group.key == "2026-04-06")
        #expect(group.count == 2)
    }

    @Test("raw frames without GPS on different UTC dates produce separate .dateGroup entries")
    func differentUTCDatesGetSeparateGroups() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-diff-dates")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let fmt = ISO8601DateFormatter()
        _ = try await db.insertFrame(
            makeBareFrame(timestamp: fmt.date(from: "2026-04-06T20:00:00Z")!), deduplicate: false)
        _ = try await db.insertFrame(
            makeBareFrame(timestamp: fmt.date(from: "2026-04-07T01:00:00Z")!), deduplicate: false)

        let activity = try await archive.recentActivity(limit: 10)
        let keys = Set(activity.compactMap { entry -> String? in
            if case .dateGroup(_, let k, _, _) = entry { return k } else { return nil }
        })

        #expect(keys == ["2026-04-06", "2026-04-07"],
                "Frames on two distinct UTC dates should produce two separate .dateGroup entries")
    }

    // MARK: Pipeline frame exclusion

    @Test("raw frames with processingRunID appear as .frame entries, not in a .dateGroup")
    func pipelineFramesExcludedFromDateGroups() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-pipeline")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let ts = ISO8601DateFormatter().date(from: "2026-04-06T20:00:00Z")!

        // Normal raw frame → should be date-grouped.
        _ = try await db.insertFrame(makeBareFrame(timestamp: ts), deduplicate: false)

        // Insert a processing_run row first (FK constraint on frames.processing_run_id).
        let runID = UUID()
        let run = ArchivedProcessingRun(id: runID, pipelineID: "test_quality", parameters: [:], createdAt: Date())
        try await db.insertProcessingRun(run, inputs: [])

        // Pipeline output frame (processingRunID != nil) → must appear as .frame, not in a group.
        _ = try await db.insertFrame(
            makeBareFrame(timestamp: ts, processingRunID: runID), deduplicate: false)

        let activity = try await archive.recentActivity(limit: 10)
        let groupCount = activity.filter { if case .dateGroup = $0 { return true } else { return false } }.count
        let frames = activity.compactMap { if case .frame(let f) = $0 { return f } else { return nil } }

        #expect(groupCount == 1, "Normal raw frame should produce one .dateGroup")
        #expect(frames.count == 1, "Pipeline frame should appear individually as .frame")
        #expect(frames.first?.processingRunID != nil)
    }

    // MARK: Non-raw frames

    @Test("non-raw (stacked) frames appear individually as .frame entries, not in a .dateGroup")
    func nonRawFramesAreIndividualEntries() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-nonraw")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let ts = ISO8601DateFormatter().date(from: "2026-04-06T22:00:00Z")!
        _ = try await db.insertFrame(
            makeBareFrame(timestamp: ts, processingLevel: .stacked), deduplicate: false)

        let activity = try await archive.recentActivity(limit: 10)
        let frames = activity.compactMap { if case .frame(let f) = $0 { return f } else { return nil } }
        let groupCount = activity.filter { if case .dateGroup = $0 { return true } else { return false } }.count

        #expect(frames.count == 1)
        #expect(frames.first?.processingLevel == .stacked)
        #expect(groupCount == 0, "Stacked frame must not produce a .dateGroup entry")
    }

    // MARK: FrameSets

    @Test("framesets appear as .frameSet entries in the activity feed")
    func frameSetsInFeed() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-frameset")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let ts = ISO8601DateFormatter().date(from: "2026-04-06T20:00:00Z")!
        let frame = makeBareFrame(timestamp: ts)
        _ = try await db.insertFrame(frame, deduplicate: false)

        let fs = ArchivedFrameSet(
            id: UUID(), name: "Orion Hα lights", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "Orion", filter: "Hα", camera: nil,
            exposureTime: nil, gain: nil, offset: nil,
            width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [frame.id])

        let activity = try await archive.recentActivity(limit: 10)
        let frameSets = activity.compactMap { if case .frameSet(let s) = $0 { return s } else { return nil } }

        #expect(frameSets.count == 1)
        #expect(frameSets.first?.name == "Orion Hα lights")
    }

    // MARK: Limit

    @Test("limit caps the total number of entries returned")
    func limitCapsResults() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-limit")
        defer { try? FileManager.default.removeItem(at: root) }

        let db = await archive.database
        let fmt = ISO8601DateFormatter()
        // 5 frames on 5 different months → 5 distinct date groups.
        for i in 1...5 {
            let ts = fmt.date(from: "2026-0\(i)-15T20:00:00Z")!
            _ = try await db.insertFrame(makeBareFrame(timestamp: ts), deduplicate: false)
        }

        let capped = try await archive.recentActivity(limit: 3)
        #expect(capped.count == 3, "recentActivity(limit: 3) must return at most 3 entries")
    }

    // MARK: Empty archive

    @Test("empty archive returns an empty activity feed")
    func emptyArchiveReturnsEmpty() async throws {
        let (archive, root) = try makeTempArchive(prefix: "recent-empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = try await archive.recentActivity(limit: 15)
        #expect(activity.isEmpty)
    }
}
