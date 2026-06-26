import Testing
import Foundation
@testable import AstrophotoArchiveKit

// MARK: - Test helpers

extension FrameArchiveMetadata {
    static func mock(
        objectName: String? = "DWB 111",
        timestamp: Date?    = Date(timeIntervalSince1970: 1_740_000_000),
        frameType: String   = "light",
        filter: String?     = "Hɑ",
        exposureTime: Double? = 300
    ) -> FrameArchiveMetadata {
        FrameArchiveMetadata(
            objectName: objectName,
            ra: 83.8221, dec: -5.3911,
            frameType: frameType,
            filter: filter,
            camera: nil,
            focalLength: nil, pixelScale: nil, temperature: nil,
            timestamp: timestamp,
            exposureTime: exposureTime,
            gain: nil, offset: nil,
            width: 6248, height: 4176, bitpix: 16,
            calibrated: false, stacked: false, stretched: false,
            processingLevel: .raw
        )
    }

}

// MARK: - FolderOrganizer tests

@Test("Two frames with the same filename, object, date, type, and filter get distinct archive paths")
func testDistinctPathsForSameFilename() {
    let meta = FrameArchiveMetadata.mock()
    let id1 = UUID()
    let id2 = UUID()
    let root = URL(fileURLWithPath: "/archive")

    let url1 = FolderOrganizer.destinationURL(for: meta, in: root, filename: "frame.fits", id: id1)
    let url2 = FolderOrganizer.destinationURL(for: meta, in: root, filename: "frame.fits", id: id2)

    #expect(url1 != url2, "Different UUIDs must produce different archive paths")
    #expect(url1.lastPathComponent.contains(id1.uuidString), "Filename should embed the frame UUID")
    #expect(url2.lastPathComponent.contains(id2.uuidString), "Filename should embed the frame UUID")
}

@Test("UUID is embedded in the archived filename between the stem and extension")
func testUUIDEmbeddedInFilename() {
    let meta = FrameArchiveMetadata.mock()
    let id   = UUID()
    let url  = FolderOrganizer.destinationURL(
        for: meta, in: URL(fileURLWithPath: "/archive"), filename: "capture.fits", id: id
    )
    #expect(url.lastPathComponent == "capture_\(id.uuidString).fits")
}

@Test("Archive directory structure is object/date/type/filter")
func testFolderStructure() {
    let meta = FrameArchiveMetadata.mock(
        objectName: "M51",
        timestamp: Date(timeIntervalSince1970: 1_740_000_000), // 2025-02-19
        frameType: "light",
        filter: "Hɑ"
    )
    let id  = UUID()
    let url = FolderOrganizer.destinationURL(
        for: meta, in: URL(fileURLWithPath: "/archive"), filename: "f.fits", id: id
    )
    let components = url.pathComponents
    // /archive/M51/2025-02-19/light/Hɑ/f_<uuid>.fits
    #expect(components.contains("M51"))
    #expect(components.contains("2025-02-19"))
    #expect(components.contains("light"))
    #expect(components.contains("Hɑ"))
}

// MARK: - Helpers

private let referenceDate = Date(timeIntervalSince1970: 1_740_000_000)

/// Returns an ArchivedFrame with the given observational attributes.
/// UUID and filePath are always unique so they can never be the deduplication key.
private func makeFrame(
    timestamp: Date? = referenceDate,
    frameType: String = "light",
    filter: String? = "Ha",
    exposureTime: Double? = 300
) -> ArchivedFrame {
    ArchivedFrame(
        id: UUID(),
        filePath: "/tmp/mock-\(UUID().uuidString).fits",
        objectName: "DWB 111",
        ra: 83.8221, dec: -5.3911,
        healpixPixel: nil,
        frameType: frameType,
        filter: filter,
        camera: nil,
        focalLength: nil, pixelScale: nil, temperature: nil,
        timestamp: timestamp,
        exposureTime: exposureTime,
        gain: nil, offset: nil,
        width: 6248, height: 4176, bitpix: 16,
        calibrated: false, stacked: false, stretched: false,
        processingLevel: .raw,
        addedAt: Date(),
        fileDate: timestamp
    )
}

/// Opens a fresh in-memory-style SQLite database in a unique temporary file.
/// The caller is responsible for cleanup via the returned URL.
private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("archivetest-\(UUID().uuidString).sqlite")
    return (try ArchiveDatabase(url: url, archiveRootPath: FileManager.default.temporaryDirectory.path), url)
}

// MARK: - Duplicate detection tests

@Test("Second insert with identical timestamp, type, filter and exposure is rejected")
func testIdenticalObservationIsRejectedAsDuplicate() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let first  = try await db.insertFrame(makeFrame())
    let second = try await db.insertFrame(makeFrame()) // same content, different UUID & path

    #expect(first  == true,  "First insert should succeed")
    #expect(second == false, "Identical observation should be rejected as duplicate")
}

@Test("Frames one second apart are distinct observations")
func testDifferentTimestampsAreDistinct() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let t2 = referenceDate.addingTimeInterval(1)

    let first  = try await db.insertFrame(makeFrame(timestamp: referenceDate))
    let second = try await db.insertFrame(makeFrame(timestamp: t2))

    #expect(first  == true, "First frame should be accepted")
    #expect(second == true, "Frame taken 1 s later should be a distinct observation")
}

@Test("Frames with different filters are distinct observations")
func testDifferentFiltersAreDistinct() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let first  = try await db.insertFrame(makeFrame(filter: "Hɑ"))
    let second = try await db.insertFrame(makeFrame(filter: "SII"))
    let third  = try await db.insertFrame(makeFrame(filter: "OIII"))

    #expect(first  == true)
    #expect(second == true, "SII frame should be distinct from Hα")
    #expect(third  == true, "OIII frame should be distinct from Hα and SII")
}

@Test("Frames with different frame types are distinct observations")
func testDifferentFrameTypesAreDistinct() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let light = try await db.insertFrame(makeFrame(frameType: "light"))
    let dark  = try await db.insertFrame(makeFrame(frameType: "dark"))
    let flat  = try await db.insertFrame(makeFrame(frameType: "flat"))

    #expect(light == true)
    #expect(dark  == true, "Dark frame should be distinct from light")
    #expect(flat  == true, "Flat frame should be distinct from light and dark")
}

@Test("Frames with different exposure times are distinct observations")
func testDifferentExposuresAreDistinct() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let short = try await db.insertFrame(makeFrame(exposureTime: 120))
    let long  = try await db.insertFrame(makeFrame(exposureTime: 300))

    #expect(short == true)
    #expect(long  == true, "120 s and 300 s exposures should be distinct")
}

@Test("Calibration frames without a timestamp are deduplicated by type and exposure")
func testTimestamplessFrameDeduplication() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    // Dark frames sometimes lack a meaningful timestamp
    let first  = try await db.insertFrame(makeFrame(timestamp: nil, frameType: "dark", filter: nil, exposureTime: 300))
    let second = try await db.insertFrame(makeFrame(timestamp: nil, frameType: "dark", filter: nil, exposureTime: 300))
    let third  = try await db.insertFrame(makeFrame(timestamp: nil, frameType: "dark", filter: nil, exposureTime: 600))

    #expect(first  == true,  "First dark should be accepted")
    #expect(second == false, "Identical dark (no timestamp) should be rejected")
    #expect(third  == true,  "Dark with different exposure should be accepted")
}

@Test("Filter comparison is case-insensitive")
func testFilterComparisonIsCaseInsensitive() async throws {
    let (db, url) = try makeTestDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let lower = try await db.insertFrame(makeFrame(filter: "ha"))
    let upper = try await db.insertFrame(makeFrame(filter: "HA"))
    let mixed = try await db.insertFrame(makeFrame(filter: "Ha"))

    #expect(lower == true,  "Lowercase 'ha' should be accepted")
    #expect(upper == false, "'HA' should be treated as the same filter as 'ha'")
    #expect(mixed == false, "'Ha' should be treated as the same filter as 'ha'")
}

// MARK: - Re-archive processingRunID update tests

@Suite("Re-archiving a duplicate frame updates its processingRunID")
struct ReArchiveRunIDTests {

    @Test("Re-archiving with a new processingRunID updates the stored run ID")
    func reArchiveUpdatesProcessingRunID() async throws {
        let (archive, root) = try makeTempArchive(prefix: "rearchive-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let run1 = try await archive.recordProcessingRun(pipelineID: "frame_stacking", parameters: [:], inputs: [])
        let run2 = try await archive.recordProcessingRun(pipelineID: "frame_stacking", parameters: [:], inputs: [])

        let (first, isNew1) = try await archive.add(fitsFile: src, processingRunID: run1.id)
        #expect(isNew1 == true)
        #expect(first.processingRunID == run1.id)

        // Same file → same signature → duplicate path; processingRunID should be updated.
        let (second, isNew2) = try await archive.add(fitsFile: src, processingRunID: run2.id)
        #expect(isNew2 == false)
        #expect(second.processingRunID == run2.id, "Re-archive must update processingRunID to the new run")

        // Verify the change is persisted in the database.
        let reloaded = try await archive.frame(id: first.id)
        #expect(reloaded?.processingRunID == run2.id)
    }

    @Test("Re-archiving without a processingRunID leaves the existing run ID intact")
    func reArchiveWithoutRunIDPreservesExisting() async throws {
        let (archive, root) = try makeTempArchive(prefix: "rearchive-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let run = try await archive.recordProcessingRun(pipelineID: "frame_stacking", parameters: [:], inputs: [])
        _ = try await archive.add(fitsFile: src, processingRunID: run.id)

        let (second, isNew2) = try await archive.add(fitsFile: src, processingRunID: nil)
        #expect(isNew2 == false)
        #expect(second.processingRunID == run.id, "Nil processingRunID must not overwrite an existing run ID")
    }

    @Test("Re-archiving sets a processingRunID on a frame that had none")
    func reArchiveSetsRunIDWhenPreviouslyNil() async throws {
        let (archive, root) = try makeTempArchive(prefix: "rearchive-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("source.fits")
        try writeTinyFITS(to: src)

        let (first, isNew1) = try await archive.add(fitsFile: src)
        #expect(isNew1 == true)
        #expect(first.processingRunID == nil)

        let run = try await archive.recordProcessingRun(pipelineID: "frame_stacking", parameters: [:], inputs: [])
        let (second, isNew2) = try await archive.add(fitsFile: src, processingRunID: run.id)
        #expect(isNew2 == false)
        #expect(second.processingRunID == run.id, "First-time run ID must be written on re-archive")

        let reloaded = try await archive.frame(id: first.id)
        #expect(reloaded?.processingRunID == run.id)
    }
}

// MARK: - Signature stability tests

@Test("frameSignature produces consistent output")
func testFrameSignatureIsStable() {
    let date = Date(timeIntervalSince1970: 1_740_000_000)
    let sig1 = ArchiveDatabase.frameSignature(fileDate: date, frameType: "Light", filter: "Ha",  exposureTime: 300)
    let sig2 = ArchiveDatabase.frameSignature(fileDate: date, frameType: "light", filter: "HA",  exposureTime: 300)
    let sig3 = ArchiveDatabase.frameSignature(fileDate: date, frameType: "light", filter: "ha",  exposureTime: 300)
    let sig4 = ArchiveDatabase.frameSignature(fileDate: date, frameType: "light", filter: "SII", exposureTime: 300)

    #expect(sig1 == sig2, "Case differences in frameType/filter should produce identical signatures")
    #expect(sig2 == sig3, "All-caps and mixed-case filter should produce identical signatures")
    #expect(sig3 != sig4, "Different filters must produce different signatures")
}

// MARK: - Processed/stacked frame deduplication bypass tests

private extension ArchivedFrame {
    func withNewID() -> ArchivedFrame {
        ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: objectName, ra: ra, dec: dec,
            healpixPixel: healpixPixel, frameType: frameType,
            filter: filter, camera: camera,
            focalLength: focalLength, pixelScale: pixelScale, temperature: temperature,
            timestamp: timestamp, exposureTime: exposureTime,
            gain: gain, offset: offset,
            width: width, height: height, bitpix: bitpix,
            calibrated: calibrated, stacked: stacked, stretched: stretched,
            processingLevel: processingLevel, addedAt: addedAt,
            fileDate: fileDate
        )
    }

    func withProcessingLevel(_ level: ProcessingLevel) -> ArchivedFrame {
        ArchivedFrame(
            id: id, filePath: filePath,
            objectName: objectName, ra: ra, dec: dec,
            healpixPixel: healpixPixel, frameType: frameType,
            filter: filter, camera: camera,
            focalLength: focalLength, pixelScale: pixelScale, temperature: temperature,
            timestamp: timestamp, exposureTime: exposureTime,
            gain: gain, offset: offset,
            width: width, height: height, bitpix: bitpix,
            calibrated: level == .calibrated,
            stacked:    level == .stacked,
            stretched:  level == .stretched,
            processingLevel: level, addedAt: addedAt,
            fileDate: fileDate
        )
    }
}

@Suite("Stacked and processed frames are never deduplicated")
struct ProcessedFrameInsertTests {

    @Test("Two stacked frames with identical signatures are both inserted")
    func stackedFramesAreNeverDeduped() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let stacked = makeFrame().withProcessingLevel(.stacked)
        let first  = try await db.insertFrame(stacked,           deduplicate: false)
        let second = try await db.insertFrame(stacked.withNewID(), deduplicate: false)

        #expect(first  == true, "First stacked insert should succeed")
        #expect(second == true, "Second stacked insert with same signature must also succeed")

        let all = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(all.count == 2, "Both stacked records must be present in the archive")
    }

    @Test("Raw frame deduplication is unaffected")
    func rawFrameDeduplicationStillWorks() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let raw    = makeFrame()   // processingLevel: .raw by default
        let first  = try await db.insertFrame(raw,           deduplicate: true)
        let second = try await db.insertFrame(raw.withNewID(), deduplicate: true)

        #expect(first  == true,  "First raw insert should succeed")
        #expect(second == false, "Identical raw observation must be rejected as a duplicate")
    }

    @Test("Archive.add creates a new record for each stacked FITS file")
    func archiveAddNeverDedupesStackedFrames() async throws {
        let (archive, root) = try makeTempArchive(prefix: "stacked-dedup")
        defer { try? FileManager.default.removeItem(at: root) }

        // Two FITS files with identical signatures but STACKED = T.
        let src1 = root.appendingPathComponent("stack1.fits")
        let src2 = root.appendingPathComponent("stack2.fits")
        try writeTinyFITS(to: src1, stacked: true)
        try writeTinyFITS(to: src2, stacked: true)

        let (first,  isNew1) = try await archive.add(fitsFile: src1)
        let (second, isNew2) = try await archive.add(fitsFile: src2)

        #expect(isNew1 == true, "First stacked frame must be inserted")
        #expect(isNew2 == true, "Second stacked frame with identical signature must also be inserted")
        #expect(first.id != second.id, "Each stacked result must get its own archive record")
    }

    @Test(
        "Calibrated and stretched frames are never deduplicated",
        arguments: [ProcessingLevel.calibrated, .stretched]
    )
    func nonRawFramesAreNeverDeduped(level: ProcessingLevel) async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame  = makeFrame().withProcessingLevel(level)
        let first  = try await db.insertFrame(frame,           deduplicate: false)
        let second = try await db.insertFrame(frame.withNewID(), deduplicate: false)

        #expect(first  == true, "First \(level) insert should succeed")
        #expect(second == true, "Second \(level) frame with same signature must also be inserted")

        let all = try await db.queryFrames(FrameQuery(), healpixPixels: nil)
        #expect(all.count == 2, "Both \(level) records must be present in the archive")
    }

    @Test("Archive.add still deduplicates raw frames with identical signatures")
    func archiveAddStillDedupesRawFrames() async throws {
        let (archive, root) = try makeTempArchive(prefix: "raw-dedup")
        defer { try? FileManager.default.removeItem(at: root) }

        let src1 = root.appendingPathComponent("raw1.fits")
        let src2 = root.appendingPathComponent("raw2.fits")
        try writeTinyFITS(to: src1)   // raw by default
        try writeTinyFITS(to: src2)

        let (first,  isNew1) = try await archive.add(fitsFile: src1)
        let (second, isNew2) = try await archive.add(fitsFile: src2)

        #expect(isNew1 == true)
        #expect(isNew2 == false, "Identical raw frames must be deduplicated")
        #expect(first.id == second.id, "Deduplication must return the existing record's ID")
    }
}
