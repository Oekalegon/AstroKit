import Foundation

/// Semantic groups for FITS header keywords, in the order they are presented
/// in the info panel.
public enum FITSKeywordGroup: String, CaseIterable, Sendable {
    case object = "Object"
    case observation = "Observation"
    case telescope = "Telescope & Optics"
    case camera = "Camera"
    case site = "Site & Conditions"
    case astrometry = "Astrometric Solution"
    case processing = "Processing & Stacking"
    case quality = "Quality"
    case file = "File Structure"
    case other = "Other"
}

/// Display metadata for a single FITS header keyword.
public struct FITSKeywordInfo: Sendable {
    public let keyword: String
    public let displayName: String
    public let group: FITSKeywordGroup
    /// Unit suffix appended to numeric values (e.g. "s", "mm", "°C").
    public let unit: String?
    /// Position within the catalog; used to order rows within a group.
    public let sortIndex: Int
}

/// A header card resolved against the catalog: original keyword plus the
/// human readable name and formatted value.
public struct FITSHeaderEntry {
    public let keyword: String
    public let displayName: String
    public let value: FITSHeaderValue
    /// Value formatted for display, including the unit suffix when known.
    public let displayValue: String
    public let unit: String?
}

/// All header entries belonging to one semantic group.
public struct FITSHeaderSection {
    public let group: FITSKeywordGroup
    public let entries: [FITSHeaderEntry]
}

/// Maps FITS header keywords to human readable names and semantic groups.
///
/// The keyword set is derived from a scan of the headers actually present in
/// the user's frame archive (capture software output, WCS solutions, and
/// AstrophotoKit pipeline results). Keywords not in the catalog fall into
/// the `.other` group and are shown with their raw name.
public enum FITSKeywordCatalog {

    /// Looks up display metadata for a keyword (case-insensitive).
    public static func info(for keyword: String) -> FITSKeywordInfo? {
        lookup[keyword.uppercased()]
    }

    /// Buckets a FITS header into catalog groups, in presentation order.
    /// Within a group, entries follow the catalog's canonical order; unknown
    /// keywords fall into `.other` under their raw name, sorted alphabetically.
    /// Empty groups are omitted.
    public static func groupedSections(from metadata: [String: FITSHeaderValue]) -> [FITSHeaderSection] {
        var buckets: [FITSKeywordGroup: [(entry: FITSHeaderEntry, sortIndex: Int)]] = [:]
        for (key, value) in metadata {
            // Skip content-less commentary cards (blank COMMENT/HISTORY lines).
            if key == "COMMENT" || key == "HISTORY" {
                let text: String
                switch value {
                case .string(let s):  text = s
                case .comment(let c): text = c
                default:              text = " "
                }
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            let info = info(for: key)
            let entry = FITSHeaderEntry(
                keyword: key,
                displayName: info?.displayName ?? key,
                value: value,
                displayValue: formatValue(value, unit: info?.unit),
                unit: info?.unit
            )
            buckets[info?.group ?? .other, default: []].append((entry, info?.sortIndex ?? Int.max))
        }
        return FITSKeywordGroup.allCases.compactMap { group in
            guard let items = buckets[group], !items.isEmpty else { return nil }
            let entries = items
                .sorted { ($0.sortIndex, $0.entry.keyword) < ($1.sortIndex, $1.entry.keyword) }
                .map(\.entry)
            return FITSHeaderSection(group: group, entries: entries)
        }
    }

    /// Formats a header value for display, appending the unit suffix if given.
    /// Floating point values are trimmed of trailing-zero noise
    /// (e.g. 120.0 → "120", 0.000513 → "0.000513").
    public static func formatValue(_ value: FITSHeaderValue, unit: String?) -> String {
        let base: String
        switch value {
        // FITS pads quoted strings to 8 characters; trim for display.
        case .string(let str):         base = str.trimmingCharacters(in: .whitespaces)
        case .integer(let int):        base = "\(int)"
        case .floatingPoint(let d):    base = formatDouble(d)
        case .boolean(let bool):       base = bool ? "Yes" : "No"
        case .comment(let comment):    base = comment.trimmingCharacters(in: .whitespaces)
        }
        if let unit = unit, !base.isEmpty {
            return "\(base) \(unit)"
        }
        return base
    }

    private static func formatDouble(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        if abs(value) < 0.001 {
            return String(format: "%g", value)
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// JSON-friendly representation of a grouped header, used by the CLI and
    /// MCP tooling. Contains the grouped/human readable entries plus the
    /// original header as a flat keyword → value object.
    public static func jsonObject(from metadata: [String: FITSHeaderValue]) -> [String: Any] {
        let groups: [[String: Any]] = groupedSections(from: metadata).map { section in
            [
                "group": section.group.rawValue,
                "entries": section.entries.map { entry -> [String: Any] in
                    var dict: [String: Any] = [
                        "keyword": entry.keyword,
                        "name": entry.displayName,
                        "value": jsonValue(entry.value),
                        "display": entry.displayValue,
                    ]
                    if let unit = entry.unit { dict["unit"] = unit }
                    return dict
                },
            ]
        }
        let original = metadata.reduce(into: [String: Any]()) { acc, item in
            acc[item.key] = jsonValue(item.value)
        }
        return ["groups": groups, "header": original]
    }

    private static func jsonValue(_ value: FITSHeaderValue) -> Any {
        switch value {
        case .string(let str):      return str
        case .integer(let int):     return int
        case .floatingPoint(let d): return d
        case .boolean(let bool):    return bool
        case .comment(let comment): return comment
        }
    }

    private static let lookup: [String: FITSKeywordInfo] = {
        var result: [String: FITSKeywordInfo] = [:]
        for (index, entry) in entries.enumerated() {
            result[entry.keyword] = FITSKeywordInfo(
                keyword: entry.keyword,
                displayName: entry.name,
                group: entry.group,
                unit: entry.unit,
                sortIndex: index
            )
        }
        return result
    }()

    private static let entries: [(keyword: String, name: String, group: FITSKeywordGroup, unit: String?)] = [
        // Object
        ("OBJECT",   "Object",                  .object, nil),
        ("OBJCTRA",  "Right Ascension",         .object, nil),
        ("OBJCTDEC", "Declination",             .object, nil),
        ("RA",       "Right Ascension",         .object, "°"),
        ("DEC",      "Declination",             .object, "°"),
        ("EQUINOX",  "Equinox",                 .object, nil),

        // Observation
        ("DATE-OBS", "Observation Start",       .observation, nil),
        ("DATE-BEG", "Observation Start",       .observation, nil),
        ("DATE-END", "Observation End",         .observation, nil),
        ("EXPSTART", "Exposure Start",          .observation, nil),
        ("EXPEND",   "Exposure End",            .observation, nil),
        ("EXPTIME",  "Exposure Time",           .observation, "s"),
        ("EXPOSURE", "Exposure Time",           .observation, "s"),
        ("DARKTIME", "Dark Time",               .observation, "s"),
        ("LIVETIME", "Live Time",               .observation, "s"),
        ("IMAGETYP", "Frame Type",              .observation, nil),
        ("FRAME",    "Frame Type",              .observation, nil),
        ("FRAMETYP", "Frame Type",              .observation, nil),
        ("FILTER",   "Filter",                  .observation, nil),
        ("OBSERVER", "Observer",                .observation, nil),
        ("TIME-SRC", "Time Source",             .observation, nil),

        // Telescope & Optics
        ("TELESCOP", "Telescope",               .telescope, nil),
        ("TELID",    "Telescope ID",            .telescope, nil),
        ("FOCALLEN", "Focal Length",            .telescope, "mm"),
        ("APTDIA",   "Aperture Diameter",       .telescope, "mm"),
        ("FOCUSPOS", "Focuser Position",        .telescope, "steps"),
        ("FOCUSTEM", "Focuser Temperature",     .telescope, "°C"),
        ("PIERSIDE", "Pier Side",               .telescope, nil),

        // Camera
        ("INSTRUME", "Camera",                  .camera, nil),
        ("IMAGERID", "Camera ID",               .camera, nil),
        ("GAIN",     "Gain",                    .camera, nil),
        ("EGAIN",    "Electron Gain",           .camera, "e⁻/ADU"),
        ("OFFSET",   "Offset",                  .camera, nil),
        ("AOFFSET",  "Analog Offset",           .camera, nil),
        ("CCD-TEMP", "Sensor Temperature",      .camera, "°C"),
        ("CCD-TMIN", "Sensor Temperature (min)", .camera, "°C"),
        ("CCD-TMAX", "Sensor Temperature (max)", .camera, "°C"),
        ("XBINNING", "Binning X",               .camera, nil),
        ("YBINNING", "Binning Y",               .camera, nil),
        ("XPIXSZ",   "Pixel Size X",            .camera, "µm"),
        ("YPIXSZ",   "Pixel Size Y",            .camera, "µm"),
        ("PIXSIZE1", "Pixel Size X",            .camera, "µm"),
        ("PIXSIZE2", "Pixel Size Y",            .camera, "µm"),
        ("BAYERPAT", "Bayer Pattern",           .camera, nil),

        // Site & Conditions
        ("OBSERVAT", "Observatory",             .site, nil),
        ("SITELAT",  "Site Latitude",           .site, nil),
        ("SITELONG", "Site Longitude",          .site, nil),
        ("GPS-LAT",  "GPS Latitude",            .site, "°"),
        ("GPS-LON",  "GPS Longitude",           .site, "°"),
        ("OBJCTALT", "Altitude",                .site, "°"),
        ("OBJCTAZ",  "Azimuth",                 .site, "°"),
        ("AIRMASS",  "Airmass",                 .site, nil),

        // Astrometric Solution (plate scale + WCS)
        ("SCALE",    "Image Scale",             .astrometry, "″/px"),
        ("PIXSCALE", "Pixel Scale",             .astrometry, "″/px"),
        ("SECPIX1",  "Plate Scale X",           .astrometry, "″/px"),
        ("SECPIX2",  "Plate Scale Y",           .astrometry, "″/px"),
        ("RADECSYS", "Coordinate Frame",        .astrometry, nil),
        ("CTYPE1",   "WCS Projection (axis 1)", .astrometry, nil),
        ("CTYPE2",   "WCS Projection (axis 2)", .astrometry, nil),
        ("CRVAL1",   "Reference RA",            .astrometry, "°"),
        ("CRVAL2",   "Reference Dec",           .astrometry, "°"),
        ("CRPIX1",   "Reference Pixel X",       .astrometry, "px"),
        ("CRPIX2",   "Reference Pixel Y",       .astrometry, "px"),
        ("CDELT1",   "Pixel Scale (axis 1)",    .astrometry, "°/px"),
        ("CDELT2",   "Pixel Scale (axis 2)",    .astrometry, "°/px"),
        ("CROTA1",   "Rotation (axis 1)",       .astrometry, "°"),
        ("CROTA2",   "Rotation (axis 2)",       .astrometry, "°"),
        ("CUNIT1",   "WCS Unit (axis 1)",       .astrometry, nil),
        ("CUNIT2",   "WCS Unit (axis 2)",       .astrometry, nil),
        ("PC1_1",    "WCS Matrix [1,1]",        .astrometry, nil),
        ("PC1_2",    "WCS Matrix [1,2]",        .astrometry, nil),
        ("PC2_1",    "WCS Matrix [2,1]",        .astrometry, nil),
        ("PC2_2",    "WCS Matrix [2,2]",        .astrometry, nil),

        // Processing & Stacking
        ("PROGRAM",  "Acquisition Software",    .processing, nil),
        ("PROC",     "Processing Software",     .processing, nil),
        ("SWCREATE", "Created By",              .processing, nil),
        ("PIPELINE", "Pipeline",                .processing, nil),
        ("NFRAMES",  "Combined Frames",         .processing, nil),
        ("STACKED",  "Stacked",                 .processing, nil),
        ("STACKCNT", "Stacked Frames",          .processing, nil),
        ("STCKMET",  "Stacking Method",         .processing, nil),
        ("STCKNORM", "Stack Normalization",     .processing, nil),
        ("STCKREJO", "Stack Rejection",         .processing, nil),
        ("STCKRJLO", "Rejection Threshold (low)",  .processing, "σ"),
        ("STCKRJHI", "Rejection Threshold (high)", .processing, "σ"),

        // Quality
        ("FWHM",     "FWHM",                    .quality, nil),
        ("SKY_BKG",  "Sky Background",          .quality, nil),

        // File Structure
        ("SIMPLE",   "Standard FITS",           .file, nil),
        ("BITPIX",   "Bits per Pixel",          .file, nil),
        ("NAXIS",    "Axes",                    .file, nil),
        ("NAXIS1",   "Width",                   .file, "px"),
        ("NAXIS2",   "Height",                  .file, "px"),
        ("NAXIS3",   "Planes",                  .file, nil),
        ("EXTEND",   "Extensions Allowed",      .file, nil),
        ("BZERO",    "Zero Offset (BZERO)",     .file, nil),
        ("BSCALE",   "Scale Factor (BSCALE)",   .file, nil),
        ("ROWORDER", "Row Order",               .file, nil),
        ("DATE",     "File Date",               .file, nil),
    ]
}
