import Foundation
import AstrophotoKit

/// Raw metadata extracted from a FITS file header for archiving purposes.
struct FrameArchiveMetadata {
    var objectName: String?
    var ra: Double?             // degrees
    var dec: Double?            // degrees
    var frameType: String
    /// True when the FITS header carries `ISMASTER = T`, indicating a combined/master calibration frame.
    var isMaster: Bool = false
    var filter: String?
    var camera: String?
    var telescope: String?
    var site: String?
    var siteLatitude: Double?   // degrees, north positive
    var siteLongitude: Double?  // degrees, east positive
    var focalLength: Double?
    /// Telescope aperture diameter in mm (FITS `APTDIA`).
    var aperture: Double?
    /// Physical (unbinned) sensor pixel size in µm.
    /// Sourced from `PIXSIZE1` directly, or `XPIXSZ / XBINNING` when only the binned size is available.
    var pixelSizeUm: Double?
    /// Pixel binning factor (FITS `XBINNING`; 1 = unbinned).
    var binning: Int?
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
    // Celestial context (written by frame_quality pipeline via CelestialContextProcessor)
    var sunAltitude: Double?         // SUNALT:   Sun altitude at obs time in degrees (neg = below horizon)
    var moonSeparation: Double?      // MOONSEP: Moon-target angular separation in degrees
    var moonIllumination: Double?    // MOONPHSE: Moon illumination fraction 0–1
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

    // MARK: - Parsing

    /// Internal (not private) so tests can exercise header parsing without a FITS file on disk.
    static func parse(
        headers: [String: FITSHeaderValue],
        width: Int, height: Int, bitpix: Int
    ) -> FrameArchiveMetadata {

        let imageType = FITSHeaderParser.stringValue(headers, keys: ["IMAGETYP", "FRAME"]) ?? ""
        let isMaster  = headers["ISMASTER"]?.boolValue ?? false
        let frameType = parseFrameType(imageType.lowercased())

        // Calibration frames do not image a sky target: any OBJECT / RA / DEC the capture
        // software wrote is leftover mount state from the preceding light frames and must
        // not be archived.
        let isCalibration = calibrationFrameTypes.contains(frameType)

        let objectName = isCalibration ? nil : FITSHeaderParser.stringValue(headers, keys: ["OBJECT"])?.nilIfBlank

        let ra  = isCalibration ? nil : FITSHeaderParser.resolveRA(headers)
        let dec = isCalibration ? nil : FITSHeaderParser.resolveDec(headers)

        let filter    = FITSHeaderParser.stringValue(headers, keys: ["FILTER"])?.nilIfBlank
        let camera    = FITSHeaderParser.stringValue(headers, keys: ["INSTRUME"])?.nilIfBlank
        let telescope = FITSHeaderParser.stringValue(headers, keys: ["TELESCOP"])?.nilIfBlank
        let site         = FITSHeaderParser.stringValue(headers, keys: ["OBSERVAT"])?.nilIfBlank
        // All keywords store degrees, north-positive latitude, east-positive longitude.
        // SITELAT/SITELONG: KStars/EKOS (INDI), N.I.N.A., Sequence Generator Pro.
        // GPS-LAT/GPS-LON:  Telescope Live remote data (QHY cameras, east-positive confirmed).
        // LAT-OBS/LONG-OBS: older convention used by some legacy software.
        // OBSGEO-B/OBSGEO-L: formal FITS/WCS standard (geodetic lat/lon).
        let siteLatitude  = FITSHeaderParser.doubleValue(headers, keys: ["SITELAT", "GPS-LAT", "LAT-OBS", "OBSGEO-B"])
        let siteLongitude = FITSHeaderParser.doubleValue(headers, keys: ["SITELONG", "GPS-LON", "LONG-OBS", "OBSGEO-L"])

        let focalLength = FITSHeaderParser.doubleValue(headers, keys: ["FOCALLEN"])
        let aperture    = FITSHeaderParser.doubleValue(headers, keys: ["APTDIA"])

        // Pixel size and binning. Normalize to the physical (unbinned) pixel size in µm.
        // XPIXSZ (MaxIm DL / INDI): binned pixel size → divide by XBINNING to get physical.
        // PIXSIZE1 (FITS standard): physical unbinned pixel size → use directly.
        let binning: Int? = headers["XBINNING"]?.intValue.map { Int($0) }
        let pixelSizeUm: Double?
        if let physicalSize = FITSHeaderParser.doubleValue(headers, keys: ["PIXSIZE1"]) {
            pixelSizeUm = physicalSize
        } else if let binnedSize = FITSHeaderParser.doubleValue(headers, keys: ["XPIXSZ"]) {
            pixelSizeUm = binnedSize / Double(binning ?? 1)
        } else {
            pixelSizeUm = nil
        }

        // Explicit scale keyword wins; otherwise derive it from the sensor pixel
        // size and focal length. XPIXSZ is the *binned* pixel size by MaxIm DL /
        // INDI convention — no binning factor must be applied. PIXSIZE1 is the
        // physical (unbinned) size and needs XBINNING.
        var pixelScale = FITSHeaderParser.doubleValue(headers, keys: ["PIXSCALE", "SCALE"])
        if pixelScale == nil, let fl = focalLength {
            if let binnedSize = FITSHeaderParser.doubleValue(headers, keys: ["XPIXSZ"]) {
                pixelScale = PixelScale.arcsecPerPixel(
                    pixelSizeMicrons: binnedSize, focalLengthMm: fl
                )
            } else if let physicalSize = FITSHeaderParser.doubleValue(headers, keys: ["PIXSIZE1"]) {
                let bin = binning ?? 1
                pixelScale = PixelScale.arcsecPerPixel(
                    pixelSizeMicrons: physicalSize, binning: bin, focalLengthMm: fl
                )
            }
        }
        let temperature   = FITSHeaderParser.doubleValue(headers, keys: ["CCD-TEMP", "CCDTEMP"])
        let positionAngle = FITSHeaderParser.doubleValue(headers, keys: ["POSANGLE", "PA", "ROTATANG"])

        let timestamp = FITSHeaderParser.parseTimestamp(headers)
        let exposureTime = FITSHeaderParser.doubleValue(headers, keys: ["EXPTIME", "EXPOSURE"])
        // GAIN = camera gain setting (dimensionless, model-specific, e.g. 0–300 for ZWO cameras).
        // EGAIN = electron conversion factor in e⁻/ADU — a distinct physical quantity.
        let gain   = FITSHeaderParser.doubleValue(headers, keys: ["GAIN"])
        let egain  = FITSHeaderParser.doubleValue(headers, keys: ["EGAIN"])
        let offset = FITSHeaderParser.doubleValue(headers, keys: ["OFFSET", "PEDESTAL"])

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
        let temperatureMin = FITSHeaderParser.doubleValue(headers, keys: ["CCD-TMIN"])
        let temperatureMax = FITSHeaderParser.doubleValue(headers, keys: ["CCD-TMAX"])

        // Quality metrics — written by AstrophotoKit analysis pipelines or compatible tools.
        let starCount          = headers["NSTARS"]?.intValue.map { Int($0) }
        let medianFWHM         = FITSHeaderParser.doubleValue(headers, keys: ["MEDFWHM"])
        let backgroundNoise    = FITSHeaderParser.doubleValue(headers, keys: ["BACKNOIS"])
        let medianEccentricity = FITSHeaderParser.doubleValue(headers, keys: ["MEDECCEN"])
        let saturatedStarCount = headers["NSATSTAR"]?.intValue.map { Int($0) }
        let hotPixelCount      = headers["NHOTPIX"]?.intValue.map  { Int($0) }
        // Celestial context — written by the frame_quality pipeline's celestial_context step.
        let sunAltitude     = FITSHeaderParser.doubleValue(headers, keys: ["SUNALT"])
        let moonSeparation  = FITSHeaderParser.doubleValue(headers, keys: ["MOONSEP"])
        let moonIllumination = FITSHeaderParser.doubleValue(headers, keys: ["MOONPHSE"])

        return FrameArchiveMetadata(
            objectName: objectName,
            ra: ra, dec: dec,
            frameType: frameType,
            isMaster: isMaster,
            filter: filter,
            camera: camera,
            telescope: telescope,
            site: site,
            siteLatitude: siteLatitude,
            siteLongitude: siteLongitude,
            focalLength: focalLength,
            aperture: aperture,
            pixelSizeUm: pixelSizeUm,
            binning: binning,
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
            hotPixelCount: hotPixelCount,
            sunAltitude: sunAltitude,
            moonSeparation: moonSeparation,
            moonIllumination: moonIllumination
        )
    }

    // MARK: - Frame type

    /// Archive labels produced by `parseFrameType` that denote calibration frames.
    /// Keep in sync with `FrameType.isCalibrationFrame` in AstrophotoKit.
    public static let calibrationFrameTypes: Set<String> = [
        "bias", "dark", "flat", "darkFlat"
    ]

    private static func parseFrameType(_ lowercased: String) -> String {
        // "Master *" IMAGETYP from external software: strip the qualifier and return the base type.
        // The master flag is carried separately via the ISMASTER keyword → FrameArchiveMetadata.isMaster.
        // The calibrated flag is carried via the CALIBRAT keyword → FrameArchiveMetadata.calibrated.
        if lowercased.contains("master") {
            if lowercased.contains("dark") && lowercased.contains("flat") { return "darkFlat" }
            if lowercased.contains("dark")  { return "dark" }
            if lowercased.contains("flat")  { return "flat" }
            if lowercased.contains("bias")  { return "bias" }
        }
        // Dark flat must be checked before either word alone.
        let dark = lowercased.contains("dark")
        let flat = lowercased.contains("flat")
        if dark && flat { return "darkFlat" }
        if lowercased.contains("bias") || lowercased == "zero" || lowercased == "offset" { return "bias" }
        if dark { return "dark" }
        if flat { return "flat" }
        if lowercased.contains("diagnostic") { return "diagnostic" }
        if lowercased.contains("light")      { return "light" }
        if lowercased.contains("science")    { return "light" }
        return lowercased.isEmpty ? "unknown" : lowercased
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
