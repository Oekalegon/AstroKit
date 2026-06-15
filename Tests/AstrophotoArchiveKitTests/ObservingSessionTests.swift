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

    @Test("frames(inSession:) excludes dark frames even when they share session_id")
    func framesInSessionExcludesDarkFrames() async throws {
        let (db, url) = try makeSessionDB()
        defer { try? FileManager.default.removeItem(at: url) }

        let light = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS)
        _ = try await db.insertFrame(light, deduplicate: false)
        try await db.backfillSessions()
        let sid = try #require(try await db.frameByID(light.id)?.sessionID)

        // Dark frame manually assigned to the same session.
        let dark = makeFrame(lat: osloLat, lon: osloLon, timestamp: osloNightTS,
                              frameType: "dark", sessionID: sid)
        _ = try await db.insertFrame(dark, deduplicate: false)

        let frames = try await db.frames(inSession: sid)
        #expect(frames.count == 1, "Dark frame must not appear in frames(inSession:)")
        #expect(frames[0].id == light.id)
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

    @Test("Archive.add() does not assign a session to a dark frame with site coordinates")
    func archiveAddSkipsSessionForDarkFrame() async throws {
        let (archive, root) = try makeTempArchive(prefix: "sess-dark")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("dark.fits")
        try writeSiteFITS(to: src, imageType: "Dark Frame", siteLat: osloLat, siteLon: osloLon)

        let (frame, _) = try await archive.add(fitsFile: src)
        #expect(frame.sessionID == nil, "Dark frames must not be assigned to a session on add()")
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
