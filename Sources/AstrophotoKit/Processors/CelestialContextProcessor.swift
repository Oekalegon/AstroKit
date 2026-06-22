import AstroKit
import Foundation
import Metal
import TabularData
import os

/// Computes celestial context metrics for a light frame using its FITS headers:
///
/// - **sun_altitude_deg**: Sun altitude at observation time (degrees; negative = below horizon).
///   Requires `SITELAT`/`SITELONG` and `DATE-OBS`.
/// - **moon_separation_deg**: Angular separation between the Moon and the target field
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

        guard let date = FITSHeaderParser.parseTimestamp(headers) else {
            Logger.processor.info("CelestialContextProcessor: no timestamp in FITS headers for \(filePath).")
            outputs["celestial_context"] = TableData(dataFrame: DataFrame())
            return
        }

        let time = AstroTime(date)
        let deg2rad = Double.pi / 180.0
        let rad2deg = 180.0 / Double.pi

        var sunAltDeg: Double? = nil
        var moonSepDeg: Double? = nil
        var moonIllum: Double? = nil

        // Sun altitude — requires observer lat/lon
        if let latDeg = FITSHeaderParser.doubleValue(headers, keys: ["SITELAT", "GPS-LAT", "LAT-OBS", "OBSGEO-B"]),
           let lonDeg = FITSHeaderParser.doubleValue(headers, keys: ["SITELONG", "GPS-LON", "LONG-OBS", "OBSGEO-L"]) {
            let obs = Observatory(longitude: lonDeg * deg2rad, latitude: latDeg * deg2rad, height: 0)
            if let sunPos = try? Sun().position(
                at: time,
                frame: .horizontal(observer: obs, jd: time.tt, refracted: true)
            ) {
                sunAltDeg = sunPos.latitude * rad2deg
            }
        }

        // Moon-target elongation — requires target RA/Dec
        if let raDeg = FITSHeaderParser.resolveRA(headers), let decDeg = FITSHeaderParser.resolveDec(headers) {
            let targetPos = SphericalPosition(
                longitude: raDeg * deg2rad,
                latitude:  decDeg * deg2rad,
                frame: .equatorial(.icrs)
            )
            if let moonPos = try? Moon().position(at: time) {
                moonSepDeg = SphericalPosition.angularSeparation(moonPos, targetPos) * rad2deg
            }
        }

        // Moon illumination — requires only time
        moonIllum = try? Moon().illuminatedFraction(at: time)

        var df = DataFrame()
        if let v = sunAltDeg    { df.append(column: Column<Double>(name: "sun_altitude_deg",    contents: [v])) }
        if let v = moonSepDeg { df.append(column: Column<Double>(name: "moon_separation_deg", contents: [v])) }
        if let v = moonIllum    { df.append(column: Column<Double>(name: "moon_illumination",   contents: [v])) }

        outputs["celestial_context"] = TableData(dataFrame: df)

        let sunStr   = sunAltDeg.map    { String(format: "%.1f°", $0) } ?? "n/a"
        let elongStr = moonSepDeg.map { String(format: "%.1f°", $0) } ?? "n/a"
        let illumStr = moonIllum.map    { String(format: "%.2f", $0)  } ?? "n/a"
        Logger.processor.info("CelestialContextProcessor: sunAlt=\(sunStr) moonSep=\(elongStr) moonIllum=\(illumStr)")
    }
}
