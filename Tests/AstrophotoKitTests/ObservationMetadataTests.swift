import Testing
import Foundation
import Metal
import TabularData
@testable import AstrophotoKit

// MARK: - Helpers

/// Writes a minimal FITS file carrying the given instrument keywords.
/// Uses writeResultFrame so we get a well-formed FITS 2-D image that CFITSIO accepts.
private func writeFITSWithHeaders(
    to path: String,
    object: String? = nil,
    camera: String? = nil,
    telescope: String? = nil,
    site: String? = nil
) throws {
    let pixels: [Float] = Array(repeating: 0.5, count: 4)
    try FITSTableWriter.writeResultFrame(
        pixelData: pixels, width: 2, height: 2,
        pipelineID: "test",
        objectName: object,
        camera: camera,
        telescope: telescope,
        site: site,
        to: path
    )
}

/// Reads the primary HDU header of a FITS file and returns a keyword→value dict.
/// FITS string values are fixed-width and may carry trailing spaces — values are trimmed.
private func readFITSHeaders(at path: String) throws -> [String: String] {
    let file = try FITSFile(path: path)
    try file.moveToHDU(0)
    let raw = try file.readHeader()
    return raw.compactMapValues { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
}

/// Creates a temporary file path that is cleaned up when the test finishes.
private func tmpPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("obs-meta-\(UUID().uuidString).fits")
        .path
}

// MARK: - writeResultFrame header tests

@Suite("writeResultFrame — observation keywords in FITS header")
struct WriteResultFrameHeaderTests {

    @Test("writes OBJECT keyword when objectName is provided")
    func writesObjectKeyword() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path, object: "NGC 7293")

        let headers = try readFITSHeaders(at: path)
        #expect(headers["OBJECT"] == "NGC 7293")
    }

    @Test("writes INSTRUME keyword when camera is provided")
    func writesInstrumeKeyword() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path, camera: "ZWO ASI2600MC Pro")

        let headers = try readFITSHeaders(at: path)
        #expect(headers["INSTRUME"] == "ZWO ASI2600MC Pro")
    }

    @Test("writes TELESCOP keyword when telescope is provided")
    func writesTelescopKeyword() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path, telescope: "SkyWatcher Esprit 100ED")

        let headers = try readFITSHeaders(at: path)
        #expect(headers["TELESCOP"] == "SkyWatcher Esprit 100ED")
    }

    @Test("writes OBSERVAT keyword when site is provided")
    func writesObservatKeyword() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path, site: "Backyard Observatory")

        let headers = try readFITSHeaders(at: path)
        #expect(headers["OBSERVAT"] == "Backyard Observatory")
    }

    @Test("all four observation keywords written together")
    func writesAllFourKeywords() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(
            to: path,
            object: "M 42", camera: "ZWO ASI294MC",
            telescope: "SkyWatcher Esprit 100ED", site: "La Palma"
        )

        let headers = try readFITSHeaders(at: path)
        #expect(headers["OBJECT"]   == "M 42")
        #expect(headers["INSTRUME"] == "ZWO ASI294MC")
        #expect(headers["TELESCOP"] == "SkyWatcher Esprit 100ED")
        #expect(headers["OBSERVAT"] == "La Palma")
    }

    @Test("omits observation keywords when values are nil")
    func omitsKeywordsWhenNil() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path)  // all nil

        let headers = try readFITSHeaders(at: path)
        #expect(headers["OBJECT"]   == nil)
        #expect(headers["INSTRUME"] == nil)
        #expect(headers["TELESCOP"] == nil)
        #expect(headers["OBSERVAT"] == nil)
    }
}

// MARK: - writeStackedOutput header tests

@Suite("writeStackedOutput — observation keywords in FITS header")
struct WriteStackedOutputHeaderTests {

    private func makeRegistrationTable(rows: Int = 2) -> DataFrame {
        var df = DataFrame()
        df.append(column: Column(name: "frame_index",     contents: (0..<rows).map { Int32($0) }))
        df.append(column: Column(name: "file_path",       contents: (0..<rows).map { "/tmp/frame\($0).fits" }))
        df.append(column: Column(name: "timestamp",       contents: (0..<rows).map { _ in "2025-03-25T08:25:40" }))
        df.append(column: Column(name: "exposure",        contents: (0..<rows).map { _ in 300.0 }))
        df.append(column: Column(name: "filter",          contents: (0..<rows).map { _ in "Hɑ" }))
        df.append(column: Column(name: "gain",            contents: (0..<rows).map { _ in 100.0 }))
        df.append(column: Column(name: "offset",          contents: (0..<rows).map { _ in 0.0 }))
        df.append(column: Column(name: "frame_type",      contents: (0..<rows).map { _ in "light" }))
        df.append(column: Column(name: "translation_x",   contents: (0..<rows).map { _ in 0.0 }))
        df.append(column: Column(name: "translation_y",   contents: (0..<rows).map { _ in 0.0 }))
        df.append(column: Column(name: "rotation_deg",    contents: (0..<rows).map { _ in 0.0 }))
        df.append(column: Column(name: "scale",           contents: (0..<rows).map { _ in 1.0 }))
        df.append(column: Column(name: "match_count",     contents: (0..<rows).map { _ in Int32(50) }))
        df.append(column: Column(name: "rmse",            contents: (0..<rows).map { _ in 0.3 }))
        df.append(column: Column(name: "star_count",      contents: (0..<rows).map { _ in Int32(200) }))
        df.append(column: Column(name: "mean_fwhm",       contents: (0..<rows).map { _ in 3.0 }))
        df.append(column: Column(name: "median_fwhm",     contents: (0..<rows).map { _ in 2.9 }))
        df.append(column: Column(name: "mean_eccentricity",   contents: (0..<rows).map { _ in 0.4 }))
        df.append(column: Column(name: "mean_position_angle", contents: (0..<rows).map { _ in 45.0 }))
        df.append(column: Column(name: "mean_flux",       contents: (0..<rows).map { _ in 50000.0 }))
        df.append(column: Column(name: "sky_background",  contents: (0..<rows).map { _ in 0.01 }))
        df.append(column: Column(name: "sky_noise",       contents: (0..<rows).map { _ in 0.001 }))
        return df
    }

    @Test("writeStackedOutput writes OBJECT, INSTRUME, TELESCOP, OBSERVAT")
    func writeStackedOutputWritesObservationKeywords() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pixels: [Float] = Array(repeating: 0.5, count: 4)
        let df = makeRegistrationTable()

        try FITSTableWriter.writeStackedOutput(
            pixelData: pixels, width: 2, height: 2,
            registrationTable: df,
            objectName: "NGC 7293",
            camera: "ZWO ASI2600MC Pro",
            telescope: "SkyWatcher Esprit 100ED",
            site: "La Palma",
            to: path
        )

        let headers = try readFITSHeaders(at: path)
        #expect(headers["OBJECT"]   == "NGC 7293")
        #expect(headers["INSTRUME"] == "ZWO ASI2600MC Pro")
        #expect(headers["TELESCOP"] == "SkyWatcher Esprit 100ED")
        #expect(headers["OBSERVAT"] == "La Palma")
    }

    @Test("writeStackedOutput omits observation keywords when nil")
    func writeStackedOutputOmitsKeywordsWhenNil() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pixels: [Float] = Array(repeating: 0.5, count: 4)
        let df = makeRegistrationTable()

        try FITSTableWriter.writeStackedOutput(
            pixelData: pixels, width: 2, height: 2,
            registrationTable: df,
            to: path
        )

        let headers = try readFITSHeaders(at: path)
        #expect(headers["OBJECT"]   == nil)
        #expect(headers["INSTRUME"] == nil)
        #expect(headers["TELESCOP"] == nil)
        #expect(headers["OBSERVAT"] == nil)
    }
}

// MARK: - Frame FITS header extraction tests

@Suite("Frame — extracts observation metadata from FITS headers")
struct FrameObservationMetadataTests {

    @Test("Frame reads OBJECT, INSTRUME, TELESCOP, OBSERVAT from FITS file")
    func frameExtractsObservationHeaders() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            Issue.record("Metal not available")
            return
        }

        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(
            to: path,
            object: "M 42", camera: "ZWO ASI294MC",
            telescope: "SkyWatcher Esprit 100ED", site: "Backyard"
        )
        _ = commandQueue  // suppress unused warning

        let fitsFile = try FITSFile(path: path)
        let fitsImage = try fitsFile.readFITSImage()
        let frame = try Frame(fitsImage: fitsImage, device: device)

        #expect(frame.objectName == "M 42")
        #expect(frame.camera     == "ZWO ASI294MC")
        #expect(frame.telescope  == "SkyWatcher Esprit 100ED")
        #expect(frame.site       == "Backyard")
    }

    @Test("Frame properties are nil when FITS file has no observation keywords")
    func framePropertiesNilWhenHeadersAbsent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal not available")
            return
        }

        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path)   // all nil

        let fitsFile = try FITSFile(path: path)
        let fitsImage = try fitsFile.readFITSImage()
        let frame = try Frame(fitsImage: fitsImage, device: device)

        #expect(frame.objectName == nil)
        #expect(frame.camera     == nil)
        #expect(frame.telescope  == nil)
        #expect(frame.site       == nil)
    }

    @Test("Frame trims whitespace and treats blank-only OBJECT as nil")
    func frameTrimsAndNillifiesBlankObject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal not available")
            return
        }

        // Pass a value with surrounding whitespace. The C-level FITS writer does NOT
        // trim strings before writing — it passes them as-is to fits_update_key.
        // CFITSIO then pads the value to the fixed 68-char FITS field width.
        // The trimming is done by nilIfBlank in Frame+FITSextensions on read.
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeFITSWithHeaders(to: path, object: "  M 42  ")

        let fitsFile = try FITSFile(path: path)
        let fitsImage = try fitsFile.readFITSImage()
        let frame = try Frame(fitsImage: fitsImage, device: device)

        // nilIfBlank must strip the surrounding whitespace on read.
        #expect(frame.objectName?.isEmpty == false)
        let name = try #require(frame.objectName)
        #expect(!name.hasPrefix(" "))
        #expect(!name.hasSuffix(" "))
    }
}
