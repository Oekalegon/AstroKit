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
        addedAt: Date()
    )
}

/// Opens a fresh in-memory-style SQLite database in a unique temporary file.
/// The caller is responsible for cleanup via the returned URL.
private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("archivetest-\(UUID().uuidString).sqlite")
    return (try ArchiveDatabase(url: url), url)
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

@Test("frameSignature produces consistent output")
func testFrameSignatureIsStable() {
    let date = Date(timeIntervalSince1970: 1_740_000_000)
    let sig1 = ArchiveDatabase.frameSignature(timestamp: date, frameType: "Light", filter: "Ha",  exposureTime: 300)
    let sig2 = ArchiveDatabase.frameSignature(timestamp: date, frameType: "light", filter: "HA",  exposureTime: 300)
    let sig3 = ArchiveDatabase.frameSignature(timestamp: date, frameType: "light", filter: "ha",  exposureTime: 300)
    let sig4 = ArchiveDatabase.frameSignature(timestamp: date, frameType: "light", filter: "SII", exposureTime: 300)

    #expect(sig1 == sig2, "Case differences in frameType/filter should produce identical signatures")
    #expect(sig2 == sig3, "All-caps and mixed-case filter should produce identical signatures")
    #expect(sig3 != sig4, "Different filters must produce different signatures")
}
