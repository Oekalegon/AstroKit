import Foundation
import AstrophotoKit

/// Raw metadata extracted from a FITS file header for archiving purposes.
struct FrameArchiveMetadata {
    var objectName: String?
    var ra: Double?             // degrees
    var dec: Double?            // degrees
    var frameType: String
    var filter: String?
    var camera: String?
    var telescope: String?
    var site: String?
    var focalLength: Double?
    var pixelScale: Double?
    var temperature: Double?
    var timestamp: Date?
    var exposureTime: Double?
    var gain: Double?
    var offset: Double?
    /// Electron conversion factor in e⁻/ADU (FITS `EGAIN` keyword).
    var egain: Double?
    var width: Int
    var height: Int
    var bitpix: Int
    var calibrated: Bool
    var stacked: Bool
    var stretched: Bool
    var processingLevel: ProcessingLevel
    var positionAngle: Double?   // degrees east of north; from POSANGLE / PA / ROTATANG
    var sessionBeg: Date?        // DATE-BEG: earliest input frame (stacked frames only)
    var sessionEnd: Date?        // DATE-END: latest input frame (stacked frames only)
    var temperatureMin: Double?  // CCD-TMIN: coldest input frame (stacked frames only)
    var temperatureMax: Double?  // CCD-TMAX: warmest input frame (stacked frames only)
    /// File creation date for deduplication: DATE header → DATE-OBS → filesystem creation date.
    var fileDate: Date?
    // MARK: - Quality metrics (written by analysis pipelines or external tools)
    var starCount: Int?              // NSTARS:   number of detected stars
    var medianFWHM: Double?          // MEDFWHM:  median FWHM in pixels (avg major+minor)
    var backgroundNoise: Double?     // BACKNOIS: background level in ADU (frame_quality) or normalised 0–1 (older pipelines)
    var medianEccentricity: Double?  // MEDECCEN: median star eccentricity (0=circular, 1=line)
    var saturatedStarCount: Int?     // NSATSTAR: number of saturated stars
    var hotPixelCount: Int?          // NHOTPIX:  number of hot pixels (dark/bias frames)
}

enum FITSHeaderReader {
    static func read(from path: String) throws -> FrameArchiveMetadata {
        let file = try FITSFile(path: path)
        try file.moveToHDU(0)
        let headers = try file.readHeader()
        let dims = try file.readImageParameters()
        var meta = parse(headers: headers, width: dims.width, height: dims.height, bitpix: Int(dims.bitpix))
        meta.fileDate = resolveFileDate(headers: headers, observationDate: meta.timestamp, path: path)
        return meta
    }

    /// Returns the best available "file creation" date using the fallback chain:
    /// DATE header → DATE-OBS (observationDate) → filesystem creation date.
    private static func resolveFileDate(
        headers: [String: FITSHeaderValue],
        observationDate: Date?,
        path: String
    ) -> Date? {
        let iso = ISO8601DateFormatter()
        if let raw = headers["DATE"]?.stringValue, let d = iso.date(from: raw) {
            return d
        }
        if let d = observationDate {
            return d
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
    }

    // MARK: - Private

    private static func parse(
        headers: [String: FITSHeaderValue],
        width: Int, height: Int, bitpix: Int
    ) -> FrameArchiveMetadata {

        let imageType = stringValue(headers, keys: ["IMAGETYP", "FRAME"]) ?? ""
        let frameType = parseFrameType(imageType.lowercased())

        // Calibration frames do not image a sky target: any OBJECT / RA / DEC the capture
        // software wrote is leftover mount state from the preceding light frames and must
        // not be archived.
        let isCalibration = calibrationFrameTypes.contains(frameType)

        let objectName = isCalibration ? nil : stringValue(headers, keys: ["OBJECT"])?.nilIfBlank

        let ra  = isCalibration ? nil : resolveRA(headers)
        let dec = isCalibration ? nil : resolveDec(headers)

        let filter    = stringValue(headers, keys: ["FILTER"])?.nilIfBlank
        let camera    = stringValue(headers, keys: ["INSTRUME"])?.nilIfBlank
        let telescope = stringValue(headers, keys: ["TELESCOP"])?.nilIfBlank
        let site      = stringValue(headers, keys: ["OBSERVAT"])?.nilIfBlank

        let focalLength   = doubleValue(headers, keys: ["FOCALLEN"])
        let pixelScale    = doubleValue(headers, keys: ["PIXSCALE", "SCALE"])
        let temperature   = doubleValue(headers, keys: ["CCD-TEMP", "CCDTEMP"])
        let positionAngle = doubleValue(headers, keys: ["POSANGLE", "PA", "ROTATANG"])

        let timestamp = parseTimestamp(headers)
        let exposureTime = doubleValue(headers, keys: ["EXPTIME", "EXPOSURE"])
        // GAIN = camera gain setting (dimensionless, model-specific, e.g. 0–300 for ZWO cameras).
        // EGAIN = electron conversion factor in e⁻/ADU — a distinct physical quantity.
        let gain   = doubleValue(headers, keys: ["GAIN"])
        let egain  = doubleValue(headers, keys: ["EGAIN"])
        let offset = doubleValue(headers, keys: ["OFFSET", "PEDESTAL"])

        // CALIBRAT: AstrophotoKit custom keyword.
        // CALSTAT: written by MaxIm DL and compatible tools — non-empty string means calibration was applied.
        // IMAGETYP containing "calibrat": written by some capture tools (e.g. "Calibrated Light").
        let calibrated = headers["CALIBRAT"]?.boolValue
            ?? (headers["CALSTAT"]?.stringValue.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false)
            || imageType.contains("calibrat")
        let stacked = headers["STACKED"]?.boolValue
            ?? ((headers["NFRAMES"]?.intValue ?? headers["NCOMBINE"]?.intValue ?? 1) > 1)
        let stretched = headers["STRETCHD"]?.boolValue ?? false

        let processingLevel: ProcessingLevel
        if stretched       { processingLevel = .stretched }
        else if stacked    { processingLevel = .stacked }
        else if calibrated { processingLevel = .calibrated }
        else               { processingLevel = .raw }

        let iso = ISO8601DateFormatter()
        let sessionBeg    = (headers["DATE-BEG"]?.stringValue).flatMap { iso.date(from: $0) }
        let sessionEnd    = (headers["DATE-END"]?.stringValue).flatMap { iso.date(from: $0) }
        let temperatureMin = doubleValue(headers, keys: ["CCD-TMIN"])
        let temperatureMax = doubleValue(headers, keys: ["CCD-TMAX"])

        // Quality metrics — written by AstrophotoKit analysis pipelines or compatible tools.
        let starCount          = headers["NSTARS"]?.intValue.map { Int($0) }
        let medianFWHM         = doubleValue(headers, keys: ["MEDFWHM"])
        let backgroundNoise    = doubleValue(headers, keys: ["BACKNOIS"])
        let medianEccentricity = doubleValue(headers, keys: ["MEDECCEN"])
        let saturatedStarCount = headers["NSATSTAR"]?.intValue.map { Int($0) }
        let hotPixelCount      = headers["NHOTPIX"]?.intValue.map  { Int($0) }

        return FrameArchiveMetadata(
            objectName: objectName,
            ra: ra, dec: dec,
            frameType: frameType,
            filter: filter,
            camera: camera,
            telescope: telescope,
            site: site,
            focalLength: focalLength,
            pixelScale: pixelScale,
            temperature: temperature,
            timestamp: timestamp,
            exposureTime: exposureTime,
            gain: gain,
            offset: offset,
            egain: egain,
            width: width, height: height, bitpix: bitpix,
            calibrated: calibrated,
            stacked: stacked,
            stretched: stretched,
            processingLevel: processingLevel,
            positionAngle: positionAngle,
            sessionBeg: sessionBeg,
            sessionEnd: sessionEnd,
            temperatureMin: temperatureMin,
            temperatureMax: temperatureMax,
            starCount: starCount,
            medianFWHM: medianFWHM,
            backgroundNoise: backgroundNoise,
            medianEccentricity: medianEccentricity,
            saturatedStarCount: saturatedStarCount,
            hotPixelCount: hotPixelCount
        )
    }

    // MARK: - Coordinate resolution

    private static func resolveRA(_ headers: [String: FITSHeaderValue]) -> Double? {
        if let d = headers["RA"]?.doubleValue { return d }
        if let s = headers["OBJCTRA"]?.stringValue { return parseSexagesimalHours(s) }
        return nil
    }

    private static func resolveDec(_ headers: [String: FITSHeaderValue]) -> Double? {
        if let d = headers["DEC"]?.doubleValue { return d }
        if let s = headers["OBJCTDEC"]?.stringValue { return parseSexagesimalDegrees(s) }
        return nil
    }

    /// Parses "HH MM SS.ss" or "HH:MM:SS.ss" to decimal degrees (× 15).
    private static func parseSexagesimalHours(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " :"))
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let hours = parts[0] + parts[1] / 60 + (parts.count > 2 ? parts[2] / 3600 : 0)
        return hours * 15.0
    }

    /// Parses "±DD MM SS.ss" or "±DD:MM:SS.ss" to decimal degrees.
    private static func parseSexagesimalDegrees(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let negative = trimmed.hasPrefix("-")
        let parts = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            .components(separatedBy: CharacterSet(charactersIn: " :"))
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let degrees = parts[0] + parts[1] / 60 + (parts.count > 2 ? parts[2] / 3600 : 0)
        return negative ? -degrees : degrees
    }

    // MARK: - Frame type

    /// Archive labels produced by `parseFrameType` that denote calibration frames.
    /// Dark flats normalize to "dark" ("dark" is matched before "flat" below).
    /// Keep in sync with `FrameType.isCalibrationFrame` in AstrophotoKit.
    static let calibrationFrameTypes: Set<String> = ["bias", "dark", "flat"]

    private static func parseFrameType(_ lowercased: String) -> String {
        if lowercased.contains("bias")       { return "bias" }
        if lowercased.contains("dark")       { return "dark" }
        if lowercased.contains("flat")       { return "flat" }
        if lowercased.contains("diagnostic") { return "diagnostic" }
        if lowercased.contains("light")      { return "light" }
        if lowercased.contains("science")    { return "light" }
        return lowercased.isEmpty ? "unknown" : lowercased
    }

    // MARK: - Timestamp

    private static func parseTimestamp(_ headers: [String: FITSHeaderValue]) -> Date? {
        guard let raw = stringValue(headers, keys: ["DATE-OBS", "DATE-BEG"]) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)

        // Try ISO 8601 with timezone first (handles "Z" and "+HH:MM" suffixes).
        // write_result_frame_fits appends "Z", so this path covers pipeline result frames.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        // Fall back to bare datetime strings without timezone (treated as UTC).
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS",
                    "yyyy-MM-dd'T'HH:mm:ss.SS",
                    "yyyy-MM-dd'T'HH:mm:ss.S",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let date = df.date(from: s) { return date }
        }
        return nil
    }

    // MARK: - Header helpers

    private static func stringValue(_ headers: [String: FITSHeaderValue], keys: [String]) -> String? {
        for key in keys {
            if let v = headers[key]?.stringValue { return v }
        }
        return nil
    }

    private static func doubleValue(_ headers: [String: FITSHeaderValue], keys: [String]) -> Double? {
        for key in keys {
            if let v = headers[key]?.doubleValue { return v }
        }
        return nil
    }
}

private extension String {
    /// Returns nil if the string is empty after trimming ASCII whitespace.
    /// Identical copy exists in AstrophotoKit/FITS/Frame+FITSextensions.swift.
    /// Cannot be shared across module boundary without making it public.
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
