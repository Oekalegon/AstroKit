import AstroKit
import Foundation
import Metal
import TabularData
import os

/// Computes celestial context metrics for a light frame using its FITS headers:
///
/// - **sun_altitude_deg**: Sun altitude at observation time (degrees; negative = below horizon).
///   Requires `SITELAT`/`SITELONG` and `DATE-OBS`.
/// - **moon_elongation_deg**: Angular separation between the Moon and the target field
///   (degrees). Requires `RA`/`DEC` (or `OBJCTRA`/`OBJCTDEC`) and `DATE-OBS`.
/// - **moon_illumination**: Moon illumination fraction 0–1 (0 = new, 1 = full).
///   Requires only `DATE-OBS`.
///
/// Any metric whose required header keywords are absent is silently omitted from the
/// output table — downstream steps must handle absent columns gracefully.
public struct CelestialContextProcessor: Processor {

    public var id: String { "celestial_context" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let frame = inputs["input_frame"] as? Frame,
              let filePath = frame.filePath else {
            Logger.processor.info("CelestialContextProcessor: no file path on input frame, producing empty table.")
            outputs["celestial_context"] = TableData(dataFrame: DataFrame())
            return
        }

        let file = try FITSFile(path: filePath)
        try file.moveToHDU(0)
        let headers = try file.readHeader()

        guard let date = parseTimestamp(headers) else {
            Logger.processor.info("CelestialContextProcessor: no timestamp in FITS headers for \(filePath).")
            outputs["celestial_context"] = TableData(dataFrame: DataFrame())
            return
        }

        let time = AstroTime(date)
        let deg2rad = Double.pi / 180.0
        let rad2deg = 180.0 / Double.pi

        var sunAltDeg: Double? = nil
        var moonElongDeg: Double? = nil
        var moonIllum: Double? = nil

        // Sun altitude — requires observer lat/lon
        if let latDeg = doubleValue(headers, keys: ["SITELAT", "GPS-LAT", "LAT-OBS", "OBSGEO-B"]),
           let lonDeg = doubleValue(headers, keys: ["SITELONG", "GPS-LON", "LONG-OBS", "OBSGEO-L"]) {
            let obs = Observatory(longitude: lonDeg * deg2rad, latitude: latDeg * deg2rad, height: 0)
            if let sunPos = try? Sun().position(
                at: time,
                frame: .horizontal(observer: obs, jd: time.tt, refracted: true)
            ) {
                sunAltDeg = sunPos.latitude * rad2deg
            }
        }

        // Moon-target elongation — requires target RA/Dec
        if let raDeg = resolveRA(headers), let decDeg = resolveDec(headers) {
            let targetPos = SphericalPosition(
                longitude: raDeg * deg2rad,
                latitude:  decDeg * deg2rad,
                frame: .equatorial(.icrs)
            )
            if let moonPos = try? Moon().position(at: time) {
                moonElongDeg = SphericalPosition.angularSeparation(moonPos, targetPos) * rad2deg
            }
        }

        // Moon illumination — requires only time
        moonIllum = try? Moon().illuminatedFraction(at: time)

        var df = DataFrame()
        if let v = sunAltDeg    { df.append(column: Column<Double>(name: "sun_altitude_deg",    contents: [v])) }
        if let v = moonElongDeg { df.append(column: Column<Double>(name: "moon_elongation_deg", contents: [v])) }
        if let v = moonIllum    { df.append(column: Column<Double>(name: "moon_illumination",   contents: [v])) }

        outputs["celestial_context"] = TableData(dataFrame: df)

        let sunStr   = sunAltDeg.map    { String(format: "%.1f°", $0) } ?? "n/a"
        let elongStr = moonElongDeg.map { String(format: "%.1f°", $0) } ?? "n/a"
        let illumStr = moonIllum.map    { String(format: "%.2f", $0)  } ?? "n/a"
        Logger.processor.info("CelestialContextProcessor: sunAlt=\(sunStr) moonElong=\(elongStr) moonIllum=\(illumStr)")
    }

    // MARK: - FITS header helpers (subset of FITSHeaderReader, inlined for target independence)

    private func doubleValue(_ headers: [String: FITSHeaderValue], keys: [String]) -> Double? {
        for key in keys {
            if let v = headers[key]?.doubleValue { return v }
        }
        return nil
    }

    private func stringValue(_ headers: [String: FITSHeaderValue], keys: [String]) -> String? {
        for key in keys {
            if let v = headers[key]?.stringValue { return v }
        }
        return nil
    }

    /// RA in degrees. Tries decimal `RA` first, then sexagesimal `OBJCTRA`.
    private func resolveRA(_ headers: [String: FITSHeaderValue]) -> Double? {
        if let d = headers["RA"]?.doubleValue { return d }
        if let s = headers["OBJCTRA"]?.stringValue { return parseSexagesimalHours(s) }
        return nil
    }

    /// Dec in degrees. Tries decimal `DEC` first, then sexagesimal `OBJCTDEC`.
    private func resolveDec(_ headers: [String: FITSHeaderValue]) -> Double? {
        if let d = headers["DEC"]?.doubleValue { return d }
        if let s = headers["OBJCTDEC"]?.stringValue { return parseSexagesimalDegrees(s) }
        return nil
    }

    /// "HH MM SS.ss" or "HH:MM:SS.ss" → decimal degrees (×15).
    private func parseSexagesimalHours(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " :"))
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let hours = parts[0] + parts[1] / 60 + (parts.count > 2 ? parts[2] / 3600 : 0)
        return hours * 15.0
    }

    /// "±DD MM SS.ss" or "±DD:MM:SS.ss" → decimal degrees.
    private func parseSexagesimalDegrees(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let negative = trimmed.hasPrefix("-")
        let parts = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            .components(separatedBy: CharacterSet(charactersIn: " :"))
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let degrees = parts[0] + parts[1] / 60 + (parts.count > 2 ? parts[2] / 3600 : 0)
        return negative ? -degrees : degrees
    }

    private func parseTimestamp(_ headers: [String: FITSHeaderValue]) -> Date? {
        guard let raw = stringValue(headers, keys: ["DATE-OBS", "DATE-BEG"]) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let date = df.date(from: s) { return date }
        }
        return nil
    }
}
