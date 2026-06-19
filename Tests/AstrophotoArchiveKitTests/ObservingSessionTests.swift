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
    exposureTime: Double = 300,
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
        exposureTime: exposureTime,
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

// Tromsø (69.65°N, 18.96°E) — polar night at December solstice.
private let tromsoLat = 69.65
private let tromsoLon = 18.96
private let tromsoWinterTS: Date = {
    ISO8601DateFormatter().date(from: "2025-12-21T00:00:00Z")!
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

    @Test("session(forFrame:) returns the session for a dark frame with a session_id assigned")
    func sessionForDarkFrameReturnsSession() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create a calibration session and assign a dark frame to it.
        let darkFrame = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS, frameType: "dark")
        _ = try await db.insertFrame(darkFrame, deduplicate: false)
        let sid = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: osloNightTS,
            exposureTime: 300, temperature: -10, filter: nil)
        try await db.updateSessionID(frameID: darkFrame.id, sessionID: sid)

        let result = try await db.session(forFrame: darkFrame.id)
        #expect(result != nil, "session(forFrame:) must return the calibration session for a dark frame")
        #expect(result?.frameType == "dark")
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

    // MARK: - frames(inSession:) contents

    @Test("frames(inSession:) returns assigned raw light frames ordered by timestamp")
    func framesInSessionContents() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let ts1 = osloNightTS
        let ts2 = osloNightTS.addingTimeInterval(600)
        let f1 = makeFrame(lat: osloLat, lon: osloLon, timestamp: ts1)
        let f2 = makeFrame(lat: osloLat, lon: osloLon, timestamp: ts2)
        _ = try await db.insertFrame(f1, deduplicate: false)
        _ = try await db.insertFrame(f2, deduplicate: false)
        try await db.backfillSessions()

        let sid = try #require(try await db.frameByID(f1.id)?.sessionID)
        let frames = try await db.frames(inSession: sid)

        #expect(frames.count == 2)
        #expect(frames[0].id == f1.id, "Results must be ordered by timestamp ascending")
        #expect(frames[1].id == f2.id)
    }

    @Test("frames(inSession:) returns all raw frames including calibration types")
    func framesInSessionIncludesAllTypes() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create a calibration session and assign two dark frames to it.
        let ts1 = osloNightTS
        let ts2 = osloNightTS.addingTimeInterval(10)
        let dark1 = makeFrame(lat: osloLat, lon: osloLon, timestamp: ts1, frameType: "dark")
        let dark2 = makeFrame(lat: osloLat, lon: osloLon, timestamp: ts2, frameType: "dark")
        _ = try await db.insertFrame(dark1, deduplicate: false)
        _ = try await db.insertFrame(dark2, deduplicate: false)
        let sid = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: ts1,
            exposureTime: 300, temperature: -10, filter: nil)
        try await db.updateSessionID(frameID: dark1.id, sessionID: sid)
        try await db.updateSessionID(frameID: dark2.id, sessionID: sid)

        let frames = try await db.frames(inSession: sid)
        #expect(frames.count == 2, "Both dark frames should appear in frames(inSession:)")
    }

    // MARK: - Polar night classification (DB level)

    @Test("findOrCreateSession classifies polar-night frame as a night session")
    func polarNightDBClassification() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = try await db.findOrCreateSession(
            timestamp: tromsoWinterTS, latDeg: tromsoLat, lonDeg: tromsoLon)
        let session = try await db.session(id: sid)
        #expect(session?.isNight == true,
                "Tromsø at winter solstice midnight should be classified as a night session")
    }

    // MARK: - Session query functions

    @Test("sessions(isNight: true) returns only night sessions")
    func sessionsFilteredByNight() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat, lonDeg: osloLon)
        _ = try await db.findOrCreateSession(timestamp: osloDayTS,   latDeg: osloLat, lonDeg: osloLon)

        let nights = try await db.sessions(isNight: true)
        let days   = try await db.sessions(isNight: false)
        let all    = try await db.sessions()

        #expect(nights.allSatisfy { $0.isNight })
        #expect(days.allSatisfy { !$0.isNight })
        #expect(all.count == nights.count + days.count)
    }

    @Test("sessions(on:) returns sessions for the given date only")
    func sessionsOnDate() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // Night of April 6 / morning April 7 — session date is April 6 (sunset date).
        _ = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat, lonDeg: osloLon)
        // Different date: polar night December 21.
        _ = try await db.findOrCreateSession(timestamp: tromsoWinterTS, latDeg: tromsoLat, lonDeg: tromsoLon)

        let iso = ISO8601DateFormatter()
        let april6 = iso.date(from: "2026-04-06T00:00:00Z")!
        let onApril6 = try await db.sessions(on: april6)
        #expect(onApril6.count == 1)
    }

    @Test("latestSessions(limit:) returns at most N sessions newest first")
    func latestSessionsLimit() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create two sessions on different nights / sites so they don't merge.
        _ = try await db.findOrCreateSession(timestamp: osloNightTS,   latDeg: osloLat,   lonDeg: osloLon)
        _ = try await db.findOrCreateSession(timestamp: tromsoWinterTS, latDeg: tromsoLat, lonDeg: tromsoLon)

        let one = try await db.latestSessions(limit: 1, isNight: nil)
        let all = try await db.latestSessions(limit: 99, isNight: nil)

        #expect(one.count == 1)
        #expect(all.count == 2)
        // Verify newest-first: April 2026 is more recent than December 2025.
        #expect(all[0].date >= all[1].date)
    }
}

// MARK: - Calibration session tests

@Suite("Calibration sessions — findOrCreateCalibrationSession and backfill")
struct CalibrationSessionTests {

    @Test("consecutive dark frames join the same session")
    func consecutiveDarksShareSession() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        // Three consecutive 300s darks at -10°C, 5 seconds apart.
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(305),
            exposureTime: 300, temperature: -10, filter: nil)
        let sid3 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(610),
            exposureTime: 300, temperature: -10, filter: nil)

        #expect(sid1 == sid2, "Consecutive darks should share a session")
        #expect(sid2 == sid3, "Consecutive darks should share a session")

        let session = try await db.session(id: sid1)
        #expect(session?.frameCount == 3)
        #expect(session?.frameType == "dark")
    }

    @Test("dark frames with a large gap get separate sessions")
    func gappedDarksGetSeparateSessions() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        // Two darks separated by more than 300 seconds after end time (300s exposure + 600s gap).
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(300 + 301),
            exposureTime: 300, temperature: -10, filter: nil)

        #expect(sid1 != sid2, "Darks with a gap > threshold should be in separate sessions")
    }

    @Test("dark frames at different temperatures get separate sessions")
    func darksDifferentTempsGetSeparateSessions() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(305),
            exposureTime: 300, temperature: 0, filter: nil)

        #expect(sid1 != sid2, "Darks at different temperatures should be in separate sessions")
    }

    @Test("flat frames with different filters get separate sessions")
    func flatsDifferentFiltersGetSeparateSessions() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "flat", timestamp: base,
            exposureTime: 5, temperature: nil, filter: "Hα")
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "flat", timestamp: base.addingTimeInterval(6),
            exposureTime: 5, temperature: nil, filter: "OIII")

        #expect(sid1 != sid2, "Flats with different filters should be in separate sessions")
    }

    @Test("calibration session name follows display-name convention")
    func calibrationSessionNames() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let ts = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!

        let darkID = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: ts,
            exposureTime: 300, temperature: -10, filter: nil)
        let flatID = try await db.findOrCreateCalibrationSession(
            frameType: "flat", timestamp: ts,
            exposureTime: 5, temperature: nil, filter: "OIII")
        let biasID = try await db.findOrCreateCalibrationSession(
            frameType: "bias", timestamp: ts,
            exposureTime: 0, temperature: nil, filter: nil)

        let darkSession = try await db.session(id: darkID)
        let flatSession = try await db.session(id: flatID)
        let biasSession = try await db.session(id: biasID)

        #expect(darkSession?.name.contains("Darks") == true)
        #expect(darkSession?.name.contains("-10°C") == true)
        #expect(flatSession?.name.contains("Flats") == true)
        #expect(flatSession?.name.contains("OIII") == true)
        #expect(biasSession?.name.contains("Bias") == true)
    }

    @Test("backfillCalibrationSessions assigns sessions to unassigned calibration frames")
    func backfillCalibrationSessionsAssigns() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        // Three consecutive dark frames without session_id.
        for i in 0..<3 {
            let frame = makeFrame(
                lat: osloLat, lon: osloLon,
                timestamp: base.addingTimeInterval(Double(i) * 305),
                frameType: "dark"
            )
            _ = try await db.insertFrame(frame, deduplicate: false)
        }

        try await db.backfillCalibrationSessions()

        let sessions = try await db.calibrationSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].frameCount == 3)
        #expect(sessions[0].frameType == "dark")
    }

    @Test("calibrationSessions() only returns calibration sessions, not light sessions")
    func calibrationSessionsFilteredCorrectly() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let ts = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!

        // One light session and one dark session with 2 frames (minimum threshold).
        _ = try await db.findOrCreateSession(timestamp: osloNightTS, latDeg: osloLat, lonDeg: osloLon)
        _ = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: ts,
            exposureTime: 300, temperature: -10, filter: nil)
        _ = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: ts.addingTimeInterval(305),
            exposureTime: 300, temperature: -10, filter: nil)

        let calibSessions = try await db.calibrationSessions()
        let lightSessions = try await db.sessions()

        #expect(calibSessions.count == 1)
        #expect(calibSessions[0].isCalibration == true)
        #expect(lightSessions.count == 1)
        #expect(lightSessions[0].isCalibration == false)
    }

    // MARK: - Bridging frame merges two separate sessions

    @Test("bridging frame absorbs the adjacent single-frame session into one")
    func bridgingFrameMergesAdjacentSessions() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let iso = ISO8601DateFormatter()
        // F1: T=0, 300s exposure → S1.end_time = 300
        // F2: T=720 (420s after F1 ended) → separate S2
        // F3: T=360, 420s exposure → end_time = 780, gap from S1.end = 60s → joins S1
        //     After joining, S1.end_time = 780; S2.start_time = 720 → |720-780| = 60 ≤ 300 → S2 absorbed
        let base = iso.date(from: "2026-06-16T22:00:00Z")!

        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(720),
            exposureTime: 300, temperature: -10, filter: nil)

        #expect(sid1 != sid2, "Before bridging, F1 and F2 must be in separate sessions")

        // Add bridging frame F3.
        let sid3 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(360),
            exposureTime: 420, temperature: -10, filter: nil)

        #expect(sid3 == sid1, "Bridging frame should join S1")

        // S2 must have been absorbed into S1.
        let merged = try await db.session(id: sid1)
        #expect(merged?.frameCount == 3, "All three frames must be in the merged session")

        let s2Gone = try await db.session(id: sid2)
        #expect(s2Gone == nil, "S2 must no longer exist after being absorbed")
    }

    @Test("merged session start_time is the earliest frame's timestamp, not the absorbing session's")
    func mergedSessionHasEarliestStartTime() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!

        // Backfill path: F1 (T=0), F3 (T=360), F2 (T=720) processed in timestamp order.
        // F2 creates S2 (start=720); backward-adjacency absorbs S1 (start=0) into S2.
        // The merged session must report start_time = base (the earliest frame), not base+720.
        _ = try await db.insertFrame(
            makeFrame(lat: 0, lon: 0, timestamp: base,
                      frameType: "dark", exposureTime: 300), deduplicate: false)
        _ = try await db.insertFrame(
            makeFrame(lat: 0, lon: 0, timestamp: base.addingTimeInterval(720),
                      frameType: "dark", exposureTime: 300), deduplicate: false)
        _ = try await db.insertFrame(
            makeFrame(lat: 0, lon: 0, timestamp: base.addingTimeInterval(360),
                      frameType: "dark", exposureTime: 420), deduplicate: false)

        try await db.backfillCalibrationSessions()

        let sessions = try await db.calibrationSessions()
        let session = try #require(sessions.first)
        #expect(session.startTime == base,
                "start_time must be the earliest frame's timestamp after a backward merge")
        #expect(session.endTime == base.addingTimeInterval(1020),
                "end_time must be the latest frame's end time (T=720 + E=300)")
    }

    @Test("backfillCalibrationSessions merges sessions bridged by a long-exposure out-of-order frame")
    func bridgingFrameMergesViaBackfill() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!

        // Three frames inserted with no session_id; backfill will process them in timestamp
        // order: F1 (T=0), F3 (T=360), F2 (T=720).
        //
        // After F3 joins S1, S1.end_time = 780. F2's gap from S1 = 720−780 = −60, so backfill
        // creates a separate S2. The backward-adjacency check in mergeAdjacentCalibrationSessions
        // must then absorb S2 (S1.end_time=780 is within 60s of S2.start_time=720).
        _ = try await db.insertFrame(
            makeFrame(lat: 0, lon: 0, timestamp: base,
                      frameType: "dark", exposureTime: 300), deduplicate: false)
        _ = try await db.insertFrame(
            makeFrame(lat: 0, lon: 0, timestamp: base.addingTimeInterval(720),
                      frameType: "dark", exposureTime: 300), deduplicate: false)
        _ = try await db.insertFrame(
            makeFrame(lat: 0, lon: 0, timestamp: base.addingTimeInterval(360),
                      frameType: "dark", exposureTime: 420), deduplicate: false)

        try await db.backfillCalibrationSessions()

        let sessions = try await db.calibrationSessions()
        #expect(sessions.count == 1, "All three frames must end up in one merged session")
        #expect(sessions[0].frameCount == 3)
    }

    // MARK: - Constraint mismatch suppresses merge

    @Test("time-adjacent dark sessions at different temperatures are not merged")
    func temperatureMismatchPreventsMerge() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!

        // S1: −10°C dark, ends at base+300.
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)

        // S2: −20°C dark, starts 60s after S1 ends — within the gap window.
        // Because temperatures differ by 10°C (> 2°C tolerance), S2 must stay separate
        // and mergeAdjacentCalibrationSessions must not absorb it into S1.
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(360),
            exposureTime: 300, temperature: -20, filter: nil)

        #expect(sid1 != sid2, "Dark sessions at −10°C and −20°C must not be merged")

        let s1 = try await db.session(id: sid1)
        let s2 = try await db.session(id: sid2)
        #expect(s1?.frameCount == 1, "S1 must still have exactly 1 frame")
        #expect(s2?.frameCount == 1, "S2 must still have exactly 1 frame")
    }

    @Test("time-adjacent flat sessions with different filters are not merged")
    func filterMismatchPreventsMerge() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!

        // S1: Hα flat, ends at base+5.
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "flat", timestamp: base,
            exposureTime: 5, temperature: nil, filter: "Hα")

        // S2: OIII flat, starts 3s after S1 ends — within the gap window.
        // Different filter → must remain a separate session.
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "flat", timestamp: base.addingTimeInterval(8),
            exposureTime: 5, temperature: nil, filter: "OIII")

        #expect(sid1 != sid2, "Flat sessions with different filters must not be merged")

        let s1 = try await db.session(id: sid1)
        let s2 = try await db.session(id: sid2)
        #expect(s1?.frameCount == 1, "Hα session must still have exactly 1 frame")
        #expect(s2?.frameCount == 1, "OIII session must still have exactly 1 frame")
    }

    // MARK: - Gap boundary

    @Test("dark frame with exactly 300s gap joins the session")
    func darkFrameAtExactGapBoundaryJoins() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        // 300s exposure → end_time = base + 300s.
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)
        // gap = (base + 600) − (base + 300) = 300s — exactly at the threshold.
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(600),
            exposureTime: 300, temperature: -10, filter: nil)

        #expect(sid1 == sid2, "A dark frame with exactly a 300s gap should join the existing session")
    }

    @Test("dark frame with 301s gap gets a new session")
    func darkFrameOverGapBoundaryGetsNewSession() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)
        // gap = (base + 601) − (base + 300) = 301s — one second over the threshold.
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base.addingTimeInterval(601),
            exposureTime: 300, temperature: -10, filter: nil)

        #expect(sid1 != sid2, "A dark frame with a 301s gap must get a new session")
    }

    // MARK: - Out-of-order frame addition

    @Test("out-of-order dark frame (timestamped before session end_time) does not join that session")
    func outOfOrderDarkDoesNotJoinNewerSession() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        // Session S1 ends at base + 300s.
        let sid1 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: base,
            exposureTime: 300, temperature: -10, filter: nil)

        // A frame from 25 hours before base has gap = -90300s — well below 0.
        let oldTS = base.addingTimeInterval(-25 * 3600)
        let sid2 = try await db.findOrCreateCalibrationSession(
            frameType: "dark", timestamp: oldTS,
            exposureTime: 300, temperature: -10, filter: nil)

        #expect(sid1 != sid2, "A dark frame timestamped before a session's end_time must not join it")
    }

    // MARK: - Backfill idempotency and mixed types

    @Test("backfillCalibrationSessions is idempotent — frame_count unchanged on second call")
    func backfillCalibrationSessionsIdempotency() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        for i in 0..<3 {
            let frame = makeFrame(
                lat: osloLat, lon: osloLon,
                timestamp: base.addingTimeInterval(Double(i) * 305),
                frameType: "dark"
            )
            _ = try await db.insertFrame(frame, deduplicate: false)
        }

        try await db.backfillCalibrationSessions()
        let sessions1 = try await db.calibrationSessions()
        let count1 = try #require(sessions1.first).frameCount

        try await db.backfillCalibrationSessions()
        let sessions2 = try await db.calibrationSessions()
        let count2 = try #require(sessions2.first).frameCount

        #expect(sessions1.count == 1)
        #expect(count1 == 3, "frame_count should be 3 after first backfill")
        #expect(sessions2.count == 1, "Second backfill must not create a duplicate session")
        #expect(count2 == 3, "frame_count must not increase on second backfill")
    }

    @Test("backfillCalibrationSessions puts bias, dark, and flat frames in separate sessions")
    func backfillCalibrationSessionsMixedTypes() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = ISO8601DateFormatter().date(from: "2026-06-16T22:00:00Z")!
        // 2 frames per type, 305s apart so each pair joins a session (makeFrame uses 300s exposure).
        for (i, type) in ["dark", "dark", "flat", "flat", "bias", "bias"].enumerated() {
            let frame = makeFrame(
                lat: osloLat, lon: osloLon,
                timestamp: base.addingTimeInterval(Double(i) * 305),
                frameType: type
            )
            _ = try await db.insertFrame(frame, deduplicate: false)
        }

        try await db.backfillCalibrationSessions()
        let sessions = try await db.calibrationSessions()
        let frameTypes = Set(sessions.map { $0.frameType })

        #expect(sessions.count == 3, "One session per calibration frame type")
        #expect(frameTypes == ["dark", "flat", "bias"])
    }
}

// MARK: - Archive-level session integration

/// Uses Archive.add() and Archive.backfillObservationMetadata() via the public API,
/// so these tests exercise the full stack including FITS reading.
private func writeSiteFITS(
    to url: URL,
    imageType: String = "Light Frame",
    dateObs: String = "2026-04-06T20:17:00Z",
    exptime: Double = 300,
    siteLat: Double,
    siteLon: Double
) throws {
    var block = Data(repeating: 32, count: 2880)

    func card(_ text: String, slot: Int) {
        let padded = text.padding(toLength: 80, withPad: " ", startingAt: 0)
        for (i, byte) in padded.utf8.prefix(80).enumerated() {
            block[slot * 80 + i] = byte
        }
    }

    card("SIMPLE  =                    T / conforms to FITS standard", slot: 0)
    card("BITPIX  =                   16 / bits per pixel", slot: 1)
    card("NAXIS   =                    0 / no data array", slot: 2)
    card("IMAGETYP= '\(imageType)'", slot: 3)
    card("DATE-OBS= '\(dateObs)'", slot: 4)
    card(String(format: "EXPTIME = %24.1f / exposure in seconds", exptime), slot: 5)
    card(String(format: "SITELAT = %24.6f / Latitude of the imaging site in degrees", siteLat), slot: 6)
    card(String(format: "SITELONG= %24.6f / Longitude of the imaging site in degrees", siteLon), slot: 7)
    card("END", slot: 8)

    try block.write(to: url)
}

@Suite("Archive-level session auto-assignment")
struct ArchiveSessionIntegrationTests {

    @Test("Archive.add() auto-assigns a session to a raw light frame with site coordinates")
    func archiveAddAutoAssignsSession() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-add")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("night.fits")
        try writeSiteFITS(to: src, siteLat: osloLat, siteLon: osloLon)

        let (frame, _) = try await archive.add(fitsFile: src)

        #expect(frame.sessionID != nil, "Raw light frame with site coords should be auto-assigned a session on add()")
        #expect(frame.siteLatitude != nil)

        let session = try await archive.session(forFrame: frame.id)
        #expect(session?.isNight == true, "Oslo at 20:17 UTC April 6 should be a night session")
    }

    @Test("Archive.add() assigns a calibration session to a dark frame with a timestamp")
    func archiveAddAssignsCalibrationSessionForDarkFrame() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-dark")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("dark.fits")
        try writeSiteFITS(to: src, imageType: "Dark Frame", siteLat: osloLat, siteLon: osloLon)

        let (frame, _) = try await archive.add(fitsFile: src)
        #expect(frame.sessionID != nil, "Dark frames with a timestamp should be auto-assigned a calibration session")

        let session = try await archive.session(forFrame: frame.id)
        #expect(session?.frameType == "dark", "Session should be a dark calibration session")
    }

    @Test("Archive.add() groups consecutive dark frames into the same session")
    func archiveAddGroupsConsecutiveDarks() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-consec")
        defer { try? FileManager.default.removeItem(at: root) }

        // Three 280s darks, each starting 300s after the previous — 20s gap between frames.
        let timestamps = ["2026-06-16T22:00:00Z", "2026-06-16T22:05:00Z", "2026-06-16T22:10:00Z"]
        var frames: [ArchivedFrame] = []
        for (i, ts) in timestamps.enumerated() {
            let src = root.appendingPathComponent("dark\(i).fits")
            try writeSiteFITS(to: src, imageType: "Dark Frame",
                              dateObs: ts, exptime: 280,
                              siteLat: osloLat, siteLon: osloLon)
            let (frame, _) = try await archive.add(fitsFile: src)
            frames.append(frame)
        }

        let sessionIDs = Set(frames.compactMap { $0.sessionID })
        #expect(sessionIDs.count == 1, "All three consecutive darks should join the same session")

        let session = try await archive.session(forFrame: frames[0].id)
        #expect(session?.frameCount == 3)
        #expect(session?.frameType == "dark")
    }

    @Test("a single dark frame is below the minimum — calibrationSessions() hides it until a second frame arrives")
    func singleDarkFrameHiddenUntilSecondFrameJoins() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-min")
        defer { try? FileManager.default.removeItem(at: root) }

        // Add the first dark frame.
        let src1 = root.appendingPathComponent("dark1.fits")
        try writeSiteFITS(to: src1, imageType: "Dark Frame",
                          dateObs: "2026-06-16T22:00:00Z", exptime: 280,
                          siteLat: osloLat, siteLon: osloLon)
        let (frame1, _) = try await archive.add(fitsFile: src1)
        #expect(frame1.sessionID != nil, "Session is created eagerly on the first frame")

        let afterOne = try await archive.calibrationSessions()
        #expect(afterOne.isEmpty, "A single-frame session must not appear in calibrationSessions()")

        // The session is still reachable directly — it exists, just not listed.
        let sessionDirect = try await archive.session(forFrame: frame1.id)
        #expect(sessionDirect != nil, "session(forFrame:) must still return the single-frame session")

        // Add the second dark frame — now the session crosses the threshold.
        let src2 = root.appendingPathComponent("dark2.fits")
        try writeSiteFITS(to: src2, imageType: "Dark Frame",
                          dateObs: "2026-06-16T22:05:00Z", exptime: 280,
                          siteLat: osloLat, siteLon: osloLon)
        _ = try await archive.add(fitsFile: src2)

        let afterTwo = try await archive.calibrationSessions()
        #expect(afterTwo.count == 1, "Session with 2 frames must now appear in calibrationSessions()")
        #expect(afterTwo[0].frameCount == 2)
    }

    @Test("Archive.add() does not assign a session to a raw light frame without site coordinates")
    func archiveAddSkipsSessionWithoutCoords() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-nocoords")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("nocoords.fits")
        // writeTinyFITS produces no SITELAT/SITELONG
        try writeTinyFITS(to: src, dateObs: "2026-04-06T20:17:00Z")

        let (frame, _) = try await archive.add(fitsFile: src)
        #expect(frame.sessionID == nil, "Frame without site coordinates should not be assigned a session")
    }

    @Test("backfillObservationMetadata assigns a session when site coords are newly discovered")
    func backfillMetadataAssignsSession() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-backfill")
        defer { try? FileManager.default.removeItem(at: root) }

        // Add a frame whose FITS file has no site coordinates yet.
        let src = root.appendingPathComponent("frame.fits")
        try writeTinyFITS(to: src, dateObs: "2026-04-06T20:17:00Z")
        let (added, _) = try await archive.add(fitsFile: src)
        #expect(added.sessionID == nil)

        // The archive copies the file into its own directory. Overwrite the archived copy
        // (not the source) with new SITELAT/SITELONG, simulating an in-place header update.
        let archivedURL = URL(fileURLWithPath: added.filePath)
        try writeSiteFITS(to: archivedURL, siteLat: osloLat, siteLon: osloLon)

        _ = try await archive.backfillObservationMetadata()

        let updated = try await archive.frame(id: added.id)
        #expect(updated?.sessionID != nil,
                "Frame should be assigned a session after backfillObservationMetadata reads new coords")
        #expect(updated?.siteLatitude != nil)

        let session = try await archive.session(forFrame: added.id)
        #expect(session?.isNight == true)
    }
}
