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
    var focalLength: Double?
    var pixelScale: Double?
    var temperature: Double?
    var timestamp: Date?
    var exposureTime: Double?
    var gain: Double?
    var offset: Double?
    var width: Int
    var height: Int
    var bitpix: Int
    var calibrated: Bool
    var stacked: Bool
    var stretched: Bool
    var processingLevel: ProcessingLevel
    var positionAngle: Double?   // degrees east of north; from POSANGLE / PA / ROTATANG
}

enum FITSHeaderReader {
    static func read(from path: String) throws -> FrameArchiveMetadata {
        let file = try FITSFile(path: path)
        try file.moveToHDU(0)
        let headers = try file.readHeader()
        let dims = try file.readImageParameters()
        return parse(headers: headers, width: dims.width, height: dims.height, bitpix: Int(dims.bitpix))
    }

    // MARK: - Private

    private static func parse(
        headers: [String: FITSHeaderValue],
        width: Int, height: Int, bitpix: Int
    ) -> FrameArchiveMetadata {

        let objectName = stringValue(headers, keys: ["OBJECT"])
            .flatMap { $0.isEmpty ? nil : $0 }

        let ra  = resolveRA(headers)
        let dec = resolveDec(headers)

        let imageType = stringValue(headers, keys: ["IMAGETYP", "FRAME"]) ?? ""
        let frameType = parseFrameType(imageType.lowercased())

        let filter = stringValue(headers, keys: ["FILTER"])?.trimmingCharacters(in: .whitespaces)
            .flatMap { $0.isEmpty ? nil : $0 }

        let camera = stringValue(headers, keys: ["INSTRUME"])?.trimmingCharacters(in: .whitespaces)
            .flatMap { $0.isEmpty ? nil : $0 }

        let focalLength   = doubleValue(headers, keys: ["FOCALLEN"])
        let pixelScale    = doubleValue(headers, keys: ["PIXSCALE", "SCALE"])
        let temperature   = doubleValue(headers, keys: ["CCD-TEMP", "CCDTEMP"])
        let positionAngle = doubleValue(headers, keys: ["POSANGLE", "PA", "ROTATANG"])

        let timestamp = parseTimestamp(headers)
        let exposureTime = doubleValue(headers, keys: ["EXPTIME", "EXPOSURE"])
        let gain   = doubleValue(headers, keys: ["GAIN"])
        let offset = doubleValue(headers, keys: ["OFFSET", "PEDESTAL"])

        let calibrated = headers["CALIBRAT"]?.boolValue
            ?? imageType.contains("calibrat")
        let stacked = headers["STACKED"]?.boolValue
            ?? ((headers["NFRAMES"]?.intValue ?? 1) > 1)
        let stretched = headers["STRETCHD"]?.boolValue ?? false

        let processingLevel: ProcessingLevel
        if stretched       { processingLevel = .stretched }
        else if stacked    { processingLevel = .stacked }
        else if calibrated { processingLevel = .calibrated }
        else               { processingLevel = .raw }

        return FrameArchiveMetadata(
            objectName: objectName,
            ra: ra, dec: dec,
            frameType: frameType,
            filter: filter,
            camera: camera,
            focalLength: focalLength,
            pixelScale: pixelScale,
            temperature: temperature,
            timestamp: timestamp,
            exposureTime: exposureTime,
            gain: gain,
            offset: offset,
            width: width, height: height, bitpix: bitpix,
            calibrated: calibrated,
            stacked: stacked,
            stretched: stretched,
            processingLevel: processingLevel,
            positionAngle: positionAngle
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

    private static func parseFrameType(_ lowercased: String) -> String {
        if lowercased.contains("bias")    { return "bias" }
        if lowercased.contains("dark")    { return "dark" }
        if lowercased.contains("flat")    { return "flat" }
        if lowercased.contains("light")   { return "light" }
        if lowercased.contains("science") { return "light" }
        return lowercased.isEmpty ? "unknown" : lowercased
    }

    // MARK: - Timestamp

    private static func parseTimestamp(_ headers: [String: FITSHeaderValue]) -> Date? {
        guard let raw = stringValue(headers, keys: ["DATE-OBS", "DATE-BEG"]) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in formats {
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

// Convenience extension used internally.
private extension String {
    func flatMap(_ transform: (String) -> String?) -> String? {
        transform(self)
    }
}
