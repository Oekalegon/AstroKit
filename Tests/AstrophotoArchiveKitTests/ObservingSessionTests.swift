import Testing
import Foundation
@testable import AstrophotoArchiveKit

// MARK: - Helpers

private func makeSessionDB() throws -> (ArchiveDatabase, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sessions-\(UUID().uuidString).sqlite")
    return (try ArchiveDatabase(url: url, archiveRootPath: FileManager.default.temporaryDirectory.path), url)
}

private func makeFrame(
    lat: Double,
    lon: Double,
    timestamp: Date,
    frameType: String = "light",
    processingLevel: ProcessingLevel = .raw,
    sessionID: UUID? = nil
) -> ArchivedFrame {
    ArchivedFrame(
        id: UUID(),
        filePath: "/tmp/session-test-\(UUID().uuidString).fits",
        objectName: "M42",
        ra: nil, dec: nil, healpixPixel: nil,
        frameType: frameType,
        filter: "Hα",
        camera: "TestCam",
        siteLatitude: lat,
        siteLongitude: lon,
        focalLength: nil, pixelScale: nil,
        temperature: -10,
        timestamp: timestamp,
        exposureTime: 300,
        gain: 100, offset: nil,
        width: nil, height: nil, bitpix: nil,
        calibrated: false, stacked: false, stretched: false,
        processingLevel: processingLevel,
        addedAt: Date(),
        sessionID: sessionID,
        fileDate: timestamp
    )
}

// Oslo (59.93°N, 10.68°E) on April 6 2026 at 20:17 UTC — well after sunset (~18:05 UTC),
// well before sunrise (~04:07 UTC April 7). Established in ERFAPlanetProviderTests.
private let osloLat  = 59.93
private let osloLon  = 10.68
private let osloNightTS: Date = {
    ISO8601DateFormatter().date(from: "2026-04-06T20:17:00Z")!
}()

// April 6 2026 at 10:00 UTC = 12:00 CEST in Oslo, well after sunrise (~04:07 UTC).
private let osloDayTS: Date = {
    ISO8601DateFormatter().date(from: "2026-04-06T10:00:00Z")!
}()

// MARK: - Suite

@Suite("Observing sessions — findOrCreateSession, backfill, and lookups")
struct ObservingSessionTests {

    // MARK: - Haversine radius grouping

    @Test("frames within 2 km share a session")
    func nearFramesShareSession() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // ~2 km north of Oslo base (0.018° latitude ≈ 2.0 km)
        let sid1 = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat,        lonDeg: osloLon)
        let sid2 = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat + 0.018, lonDeg: osloLon)

        #expect(sid1 == sid2, "Frames ~2 km apart should share a session")

        let session = try await db.session(id: sid1)
        #expect(session?.frameCount == 2)
    }

    @Test("frames more than 3 km apart get separate sessions")
    func farFramesGetSeparateSessions() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // ~5 km north of Oslo base (0.045° latitude ≈ 5.0 km)
        let sid1 = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat,        lonDeg: osloLon)
        let sid2 = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat + 0.045, lonDeg: osloLon)

        #expect(sid1 != sid2, "Frames ~5 km apart should be in separate sessions")
    }

    // MARK: - Day session classification

    @Test("frame captured at solar noon gets a day session")
    func solarNoonIsDay() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = try await db.findOrCreateSession(timestamp: osloDayTS, latDeg: osloLat, lonDeg: osloLon)
        let session = try await db.session(id: sid)

        #expect(session?.isNight == false, "Frame at Oslo solar noon should produce a day session")
    }

    // MARK: - session(forFrame:) filtering

    @Test("session(forFrame:) returns nil for a dark frame even when session_id is assigned")
    func sessionForDarkFrameIsNil() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create a valid session via a raw light frame.
        let lightFrame = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS)
        _ = try await db.insertFrame(lightFrame, deduplicate: false)
        let sid = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat, lonDeg: osloLon)
        try await db.updateSessionID(frameID: lightFrame.id, sessionID: sid)

        // Insert a dark frame with that same session_id explicitly pre-set.
        let darkFrame = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS,
                                   frameType: "dark", sessionID: sid)
        _ = try await db.insertFrame(darkFrame, deduplicate: false)

        // session(forFrame:) must return nil because dark frames are excluded by the filter.
        let result = try await db.session(forFrame: darkFrame.id)
        #expect(result == nil, "session(forFrame:) must return nil for a dark frame")
    }

    @Test("session(forFrame:) returns nil for a processed (non-raw) light frame")
    func sessionForProcessedFrameIsNil() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat, lonDeg: osloLon)

        // Calibrated light frame (processing_level = 'calibrated') with session_id set.
        let calibrated = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS,
                                    processingLevel: .calibrated, sessionID: sid)
        _ = try await db.insertFrame(calibrated, deduplicate: false)

        let result = try await db.session(forFrame: calibrated.id)
        #expect(result == nil, "session(forFrame:) must return nil for a non-raw frame")
    }

    // MARK: - backfillSessions idempotency

    @Test("backfillSessions is idempotent — frame_count is unchanged on second call")
    func backfillIdempotency() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // Insert 3 frames without session_id (bypassing the auto-assign in Archive.add).
        var frameIDs: [UUID] = []
        for _ in 0..<3 {
            let frame = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS)
            _ = try await db.insertFrame(frame, deduplicate: false)
            frameIDs.append(frame.id)
        }

        try await db.backfillSessions()

        // Retrieve the session via the first frame's stored session_id — avoid calling
        // findOrCreateSession here because that would increment frame_count again.
        let sid = try #require(try await db.frameByID(frameIDs[0])?.sessionID,
                               "Frame should have a session after backfill")
        let countAfterFirst = try await db.session(id: sid)?.frameCount ?? 0

        // Second backfill: already-assigned frames are skipped, count must not change.
        try await db.backfillSessions()
        let countAfterSecond = try await db.session(id: sid)?.frameCount ?? 0

        #expect(countAfterFirst  == 3, "frame_count should be 3 after first backfill")
        #expect(countAfterSecond == 3, "frame_count should still be 3 after second backfill")
    }
}
