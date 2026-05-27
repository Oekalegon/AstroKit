import Foundation
import Metal

extension Frame {
    /// Create a Frame from a FITSImage.
    ///
    /// This initializer creates a Frame instance from a FITSImage, including creating
    /// the Metal texture from the image data. Metadata such as frame type, filter,
    /// timestamp, exposure, gain, and offset are extracted from the FITS header if available.
    ///
    /// The texture is kept as grayscale (r32Float) for memory efficiency.
    /// Convert to RGBA only when needed (e.g., for color overlays in StarDetectionOverlayProcessor).
    /// - Parameters:
    ///   - fitsImage: The FITS image to create the frame from
    ///   - device: The Metal device to use for creating the texture
    ///   - outputProcess: The output link for this frame (the process that produces it)
    ///   - inputProcesses: The input links for this frame (the processes that consume it)
    ///   - filePath: The source file path, if the frame was loaded from disk
    /// - Throws: An error if the texture cannot be created
    public init(
        fitsImage: FITSImage,
        device: MTLDevice,
        outputProcess: ProcessDataLink? = nil,
        inputProcesses: [ProcessDataLink] = [],
        filePath: String? = nil
    ) throws {
        // Create the texture from the FITS image as r32Float (pixelData is always Float32)
        // This ensures correct data layout regardless of original FITS data type
        // Keep as grayscale for memory efficiency - only convert to RGBA when needed (e.g., for color overlays)
        let texture = try fitsImage.createMetalTexture(device: device, pixelFormat: .r32Float)

        // Determine color space from the texture's pixel format
        let colorSpace = ColorSpace.from(metalPixelFormat: texture.pixelFormat) ?? .greyscale

        // Extract frame type. Software writes diverse values: "Light Frame", "LIGHT", "light", etc.
        var frameType: FrameType = .light
        if let s = fitsImage.metadata["FRAMETYP"]?.stringValue ?? fitsImage.metadata["IMAGETYP"]?.stringValue {
            frameType = Frame.frameType(from: s)
        }

        // Extract filter using case-insensitive alias matching (rawValue lookup is insufficient
        // because the enum uses Unicode chars like Hɑ and uppercase names like OIII/SII).
        // filterName preserves the canonical or raw string so exotic filters (e.g. "NII")
        // are never silently replaced with "unknown".
        var filter: Filter = .none
        var filterName: String? = nil
        if let filterStr = fitsImage.metadata["FILTER"]?.stringValue {
            (filter, filterName) = Frame.filterAndName(from: filterStr)
        }

        // Extract observation timestamp from DATE-OBS.
        // FITS files from common software (NINA, SharpCap, MaximDL) often omit the timezone
        // designator, so we try multiple formats and treat bare datetimes as UTC.
        var timestamp: Date? = nil
        if let dateStr = fitsImage.metadata["DATE-OBS"]?.stringValue {
            timestamp = Frame.parseDate(dateStr)
        }

        // Extract exposure time. Some FITS writers store whole-number seconds as integers,
        // so check both double and integer representations.
        var exposureTime: Double? = nil
        for key in ["EXPTIME", "EXPOSURE"] {
            if let v = fitsImage.metadata[key]?.doubleValue { exposureTime = v; break }
            if let v = fitsImage.metadata[key]?.intValue    { exposureTime = Double(v); break }
        }

        // Extract camera gain setting (dimensionless value, e.g. 0–300 for ZWO cameras).
        // GAIN and EGAIN are two distinct quantities:
        //   GAIN  = camera gain setting (depends on camera model, not in physical units)
        //   EGAIN = actual conversion factor in electrons per ADU (e⁻/ADU, a small positive real)
        var gain: Double? = nil
        if let v = fitsImage.metadata["GAIN"]?.doubleValue {
            gain = v
        } else if let v = fitsImage.metadata["GAIN"]?.intValue {
            gain = Double(v)
        }

        // Extract electron conversion factor (e⁻/ADU) from the EGAIN keyword.
        var egain: Double? = nil
        if let v = fitsImage.metadata["EGAIN"]?.doubleValue {
            egain = v
        }

        // Extract camera offset / bias pedestal.
        var offset: Double? = nil
        if let v = fitsImage.metadata["OFFSET"]?.doubleValue {
            offset = v
        } else if let v = fitsImage.metadata["OFFSET"]?.intValue {
            offset = Double(v)
        } else if let v = fitsImage.metadata["AOFFSET"]?.doubleValue {
            offset = v
        }

        // Initialize using the main initializer
        self.init(
            type: frameType,
            filter: filter,
            colorSpace: colorSpace,
            dataType: fitsImage.dataType,
            texture: texture,
            outputProcess: outputProcess,
            inputProcesses: inputProcesses,
            filePath: filePath,
            timestamp: timestamp,
            exposureTime: exposureTime,
            gain: gain,
            offset: offset,
            filterName: filterName,
            fitsMinValue: Double(fitsImage.originalMinValue),
            fitsMaxValue: Double(fitsImage.originalMaxValue),
            egain: egain
        )
    }

    // MARK: - FITS header value parsers

    /// Parse a FITS DATE-OBS string into a Date.
    /// Handles ISO 8601 with and without timezone (treated as UTC when absent),
    /// with and without fractional seconds.
    static func parseDate(_ dateStr: String) -> Date? {
        let s = dateStr.trimmingCharacters(in: .whitespaces)

        // Try standard ISO 8601 with timezone first (e.g. "2024-03-15T22:30:00Z")
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFull.date(from: s) { return d }

        isoFull.formatOptions = [.withInternetDateTime]
        if let d = isoFull.date(from: s) { return d }

        // Many FITS files omit the timezone (treat as UTC)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS",
                    "yyyy-MM-dd'T'HH:mm:ss.SS",
                    "yyyy-MM-dd'T'HH:mm:ss.S",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Map a FITS FILTER string to a (Filter, displayName) pair.
    /// The display name is the canonical name for known filters (e.g. "Hɑ", "SII", "OIII")
    /// or the raw trimmed FITS string for unrecognised values (e.g. "NII", "H-beta").
    /// Returns nil for the display name when no filter is in use.
    static func filterAndName(from fitsString: String) -> (Filter, String?) {
        let raw = fitsString.trimmingCharacters(in: .whitespaces)
        let s   = raw.lowercased()
        switch s {
        case "ha", "h-alpha", "h_alpha", "halpha", "h alpha", "hα", "hɑ":  return (.Hɑ,         "Hɑ")
        case "oiii", "o3", "o-iii", "o_iii":                        return (.OIII,        "OIII")
        case "sii", "s2", "s-ii", "s_ii":                           return (.SII,         "SII")
        case "lum", "luminance", "luminosity", "l", "clear", "clr": return (.luminosity,  "Lum")
        case "red":                                                  return (.red,         "Red")
        case "green":                                                return (.green,       "Green")
        case "blue":                                                 return (.blue,        "Blue")
        case "r":                                                    return (.R,           "R")
        case "g":                                                    return (.green,       "Green")
        case "b":                                                    return (.B,           "B")
        case "v":                                                    return (.V,           "V")
        case "u":                                                    return (.U,           "U")
        case "i":                                                    return (.I,           "I")
        case "none", "no filter", "nofilter", "":                   return (.none,        nil)
        default:
            // Unknown filter — preserve the raw string so "NII", "H-beta", etc. are not lost
            return (.unknown, raw.isEmpty ? nil : raw)
        }
    }

    /// Map a FITS IMAGETYP / FRAMETYP string to a FrameType enum value.
    /// Case-insensitive; handles common values from major FITS-producing applications.
    static func frameType(from fitsString: String) -> FrameType {
        let s = fitsString.lowercased().trimmingCharacters(in: .whitespaces)
        switch s {
        case "light", "light frame", "science":              return .light
        case "dark", "dark frame":                           return .dark
        case "bias", "bias frame", "offset", "zero":        return .bias
        case "flat", "flat field", "flat frame":             return .flat
        case "darkflat", "dark flat", "flat dark":           return .darkFlat
        case "master bias", "masterbias":                    return .masterBias
        case "master dark", "masterdark":                    return .masterDark
        case "master flat", "masterflat":                    return .masterFlat
        default:                                             return .unknown
        }
    }
}
