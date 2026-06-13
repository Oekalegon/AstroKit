import Testing
import Foundation
import SQLite3
import AstrophotoKit
@testable import AstrophotoArchiveKit

// MARK: - Helpers

/// Writes a tiny FITS file carrying OBJECT, RA, and DEC alongside the given IMAGETYP,
/// mimicking capture software that records mount state on every frame type.
private func writeFITS(imageType: String, to url: URL) throws {
    let pixels: [Float] = Array(repeating: 0.5, count: 4)
    try FITSTableWriter.writeResultFrame(
        pixelData: pixels, width: 2, height: 2,
        pipelineID: "test",
        imageType: imageType,
        objectName: "M42",
        ra: 83.8221, dec: -5.3911,
        to: url.path
    )
}

/// Executes SQL against the database file with a direct SQLite connection.
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

/// Returns one row of nullable text/real values for the given query.
private func queryRow(_ sql: String, columns: Int, on url: URL) throws -> [String?] {
    var db: OpaquePointer?
    try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    try #require(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    try #require(sqlite3_step(stmt) == SQLITE_ROW)
    return (0..<Int32(columns)).map { i in
        sqlite3_column_type(stmt, i) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(stmt, i))
    }
}

// MARK: - FITSHeaderReader

@Suite("Calibration frames carry no object / RA / DEC (ASTR-51)")
struct CalibrationFrameMetadataTests {

    @Test("calibration frame types drop OBJECT, RA, and DEC on read", arguments: [
        ("Bias Frame", "bias"),
        ("Dark Frame", "dark"),
        ("Flat Field", "flat"),
        ("Dark Flat",  "dark"),   // dark flats normalize to "dark"
    ])
    func calibrationDropsTargetMetadata(imageType: String, expectedType: String) throws {
        let url = tempFITSURL("cal")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFITS(imageType: imageType, to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(meta.frameType == expectedType)
        #expect(meta.objectName == nil)
        #expect(meta.ra == nil)
        #expect(meta.dec == nil)
    }

    @Test("light frames keep OBJECT, RA, and DEC")
    func lightKeepsTargetMetadata() throws {
        let url = tempFITSURL("light")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFITS(imageType: "Light Frame", to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(meta.frameType == "light")
        #expect(meta.objectName == "M42")
        let ra = try #require(meta.ra)
        #expect(abs(ra - 83.8221) < 1e-4)
        let dec = try #require(meta.dec)
        #expect(abs(dec - (-5.3911)) < 1e-4)
    }

    @Test("archived calibration frame stores no object, coordinates, or healpix pixel")
    func archiveAddDropsTargetMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("dark.fits")
        try writeFITS(imageType: "Dark Frame", to: src)

        let archive = try Archive(configuration: ArchiveConfiguration(rootURL: root))
        let (frame, isNew) = try await archive.add(fitsFile: src)

        #expect(isNew)
        #expect(frame.frameType == "dark")
        #expect(frame.objectName == nil)
        #expect(frame.ra == nil)
        #expect(frame.dec == nil)
        #expect(frame.healpixPixel == nil)
    }
}

// MARK: - Migration v25

@Suite("Migration v25 — clears object/coordinates on existing calibration rows")
struct CalibrationMigrationTests {

    @Test("v25 nulls object/ra/dec/healpix on calibration frames but not lights")
    func migrationClearsCalibrationRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migr25-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let rootPath = FileManager.default.temporaryDirectory.path

        // Create a fully migrated database, then simulate a pre-v25 archive:
        // insert calibration rows that still carry target metadata and rewind
        // user_version so the next open re-runs v25.
        _ = try ArchiveDatabase(url: url, archiveRootPath: rootPath)
        try exec("""
            INSERT INTO frames (id, file_path, object_name, ra, dec, healpix_pixel,
                                frame_type, added_at, frame_signature)
            VALUES ('f-dark',  'a.fits', 'M42', 83.8, -5.4, 12345, 'dark',  '2026-06-11', 'sig-dark'),
                   ('f-light', 'b.fits', 'M42', 83.8, -5.4, 12345, 'light', '2026-06-11', 'sig-light');
            INSERT INTO frame_sets (id, name, frame_type, object_name, created_at)
            VALUES ('fs-flat',  'Flats',  'flat',  'M42', '2026-06-11'),
                   ('fs-light', 'Lights', 'light', 'M42', '2026-06-11');
            -- v27 added this column via ALTER TABLE; drop it so the replay can re-add it.
            ALTER TABLE frame_sets DROP COLUMN criteria;
            PRAGMA user_version = 24;
            """, on: url)

        // Reopen — migrations resume from v24 and apply v25.
        _ = try ArchiveDatabase(url: url, archiveRootPath: rootPath)

        let dark = try queryRow(
            "SELECT object_name, ra, dec, healpix_pixel FROM frames WHERE id = 'f-dark'",
            columns: 4, on: url
        )
        #expect(dark == [nil, nil, nil, nil])

        let light = try queryRow(
            "SELECT object_name, ra, dec, healpix_pixel FROM frames WHERE id = 'f-light'",
            columns: 4, on: url
        )
        #expect(light[0] == "M42")
        #expect(light[1] != nil)
        #expect(light[2] != nil)
        #expect(light[3] != nil)

        let flatSet = try queryRow(
            "SELECT object_name FROM frame_sets WHERE id = 'fs-flat'", columns: 1, on: url
        )
        #expect(flatSet == [nil])

        let lightSet = try queryRow(
            "SELECT object_name FROM frame_sets WHERE id = 'fs-light'", columns: 1, on: url
        )
        #expect(lightSet == ["M42"])
    }

    @Test("v26 re-clears an object re-added to a calibration row after v25")
    func migrationReclearsCalibrationObject() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migr26-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let rootPath = FileManager.default.temporaryDirectory.path

        // Simulate the post-v25 regression: a stale-binary backfill wrote object_name
        // back onto calibration rows (ra/dec stayed NULL — backfill never writes those).
        _ = try ArchiveDatabase(url: url, archiveRootPath: rootPath)
        try exec("""
            INSERT INTO frames (id, file_path, object_name, frame_type, added_at, frame_signature)
            VALUES ('f-bias',  'a.fits', 'HD 116798', 'bias',       '2026-06-12', 'sig-bias'),
                   ('f-flat',  'b.fits', 'M 101',     'flat',       '2026-06-12', 'sig-flat'),
                   ('f-diag',  'c.fits', 'NGC 6910',  'diagnostic', '2026-06-12', 'sig-diag'),
                   ('f-light', 'd.fits', 'M 101',     'light',      '2026-06-12', 'sig-light');
            -- v27 added this column via ALTER TABLE; drop it so the replay can re-add it.
            ALTER TABLE frame_sets DROP COLUMN criteria;
            PRAGMA user_version = 25;
            """, on: url)

        // Reopen — migrations resume from v25 and apply v26.
        _ = try ArchiveDatabase(url: url, archiveRootPath: rootPath)

        let objects = try queryRow(
            """
            SELECT (SELECT object_name FROM frames WHERE id = 'f-bias'),
                   (SELECT object_name FROM frames WHERE id = 'f-flat'),
                   (SELECT object_name FROM frames WHERE id = 'f-diag'),
                   (SELECT object_name FROM frames WHERE id = 'f-light')
            """,
            columns: 4, on: url
        )
        #expect(objects[0] == nil)
        #expect(objects[1] == nil)
        #expect(objects[2] == "NGC 6910", "Diagnostic frames may carry an object")
        #expect(objects[3] == "M 101")
    }
}

// MARK: - Backfill

@Suite("backfillObservationMetadata — object only for light/diagnostic frames")
struct CalibrationBackfillTests {

    @Test("backfill does not re-add OBJECT to a calibration frame whose FITS file carries one")
    func backfillSkipsCalibrationObject() async throws {
        let (archive, root) = try makeTempArchive(prefix: "cal-backfill")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("dark.fits")
        try writeFITS(imageType: "Dark Frame", to: src)
        _ = try await archive.add(fitsFile: src)

        let result = try await archive.backfillObservationMetadata()
        #expect(result.updated == 0)
        #expect(result.failed == 0)

        var query = FrameQuery()
        query.frameTypes = ["dark"]
        let frame = try #require(try await archive.frames(matching: query).first)
        #expect(frame.objectName == nil)
        #expect(frame.ra == nil)
        #expect(frame.dec == nil)
    }

    @Test("backfill still restores a missing OBJECT on light and diagnostic frames", arguments: [
        "Light Frame",
        "Diagnostic",
    ])
    func backfillRestoresLightObject(imageType: String) async throws {
        let (archive, root) = try makeTempArchive(prefix: "cal-backfill")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("frame.fits")
        try writeFITS(imageType: imageType, to: src)
        let (added, _) = try await archive.add(fitsFile: src)
        #expect(added.objectName == "M42")

        // Simulate a pre-existing row archived without an object.
        try exec(
            "UPDATE frames SET object_name = NULL WHERE id = '\(added.id.uuidString)'",
            on: root.appendingPathComponent("archive.db")
        )

        let result = try await archive.backfillObservationMetadata()
        #expect(result.updated == 1)

        let frame = try #require(try await archive.frame(id: added.id))
        #expect(frame.objectName == "M42")
    }
}

// MARK: - FrameType.isCalibrationFrame

@Suite("FrameType.isCalibrationFrame")
struct FrameTypeCalibrationTests {

    @Test("bias/dark/flat families are calibration frames")
    func calibrationCases() {
        let calibration: [FrameType] = [
            .bias, .masterBias,
            .dark, .calibratedDark, .masterDark,
            .flat, .calibratedFlat, .masterFlat,
            .darkFlat, .calibratedDarkFlat, .masterDarkFlat,
        ]
        for type in calibration {
            #expect(type.isCalibrationFrame, "\(type) should be a calibration frame")
        }
    }

    @Test("light and non-imaging types are not calibration frames")
    func nonCalibrationCases() {
        let nonCalibration: [FrameType] = [
            .light, .callibratedLight, .processedLight,
            .intermediate, .diagnostic, .unknown, .multiple,
        ]
        for type in nonCalibration {
            #expect(!type.isCalibrationFrame, "\(type) should not be a calibration frame")
        }
    }
}
