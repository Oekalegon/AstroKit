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
    /// Standard number of decimal places for numeric values (e.g. 1 for FWHM,
    /// 5 for RA/Dec in degrees). `nil` means no standard precision: the value
    /// is shown trimmed of trailing-zero noise instead.
    public let precision: Int?
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
                displayValue: formatValue(value, unit: info?.unit, precision: info?.precision),
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
    /// Numeric values are shown with `precision` decimal places when the
    /// keyword has a standard precision (e.g. FWHM → 1, RA/Dec → 5);
    /// otherwise floating point values are trimmed of trailing-zero noise
    /// (e.g. 120.0 → "120", 0.000513 → "0.000513").
    public static func formatValue(_ value: FITSHeaderValue, unit: String?, precision: Int? = nil) -> String {
        let base: String
        switch value {
        // FITS pads quoted strings to 8 characters; trim for display.
        case .string(let str):         base = str.trimmingCharacters(in: .whitespaces)
        case .integer(let int):
            if let precision = precision, precision > 0 {
                base = String(format: "%.\(precision)f", Double(int))
            } else {
                base = "\(int)"
            }
        case .floatingPoint(let d):
            if let precision = precision {
                base = String(format: "%.\(precision)f", d)
            } else {
                base = trimmedDouble(d)
            }
        case .boolean(let bool):       base = bool ? "Yes" : "No"
        case .comment(let comment):    base = comment.trimmingCharacters(in: .whitespaces)
        }
        if let unit = unit, !base.isEmpty {
            return "\(base) \(unit)"
        }
        return base
    }

    private static func trimmedDouble(_ value: Double) -> String {
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

    // MARK: - Catalog data

    private struct Entry {
        let keyword: String
        let name: String
        let group: FITSKeywordGroup
        let unit: String?
        let precision: Int?

        init(_ keyword: String, _ name: String, _ group: FITSKeywordGroup,
             unit: String? = nil, precision: Int? = nil) {
            self.keyword = keyword
            self.name = name
            self.group = group
            self.unit = unit
            self.precision = precision
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
                precision: entry.precision,
                sortIndex: index
            )
        }
        return result
    }()

    // Precisions follow common astrophotography conventions:
    // RA/Dec in degrees → 5 decimals (≈0.04″), alt/az → 2, plate scale → 3,
    // temperatures → 1, FWHM → 1, pixel sizes → 2.
    private static let entries: [Entry] = [
        // Object
        Entry("OBJECT",   "Object",                  .object),
        Entry("OBJCTRA",  "Right Ascension",         .object),
        Entry("OBJCTDEC", "Declination",             .object),
        Entry("RA",       "Right Ascension",         .object, unit: "°", precision: 5),
        Entry("DEC",      "Declination",             .object, unit: "°", precision: 5),
        Entry("EQUINOX",  "Equinox",                 .object, precision: 0),

        // Observation
        Entry("DATE-OBS", "Observation Start",       .observation),
        Entry("DATE-BEG", "Observation Start",       .observation),
        Entry("DATE-END", "Observation End",         .observation),
        Entry("EXPSTART", "Exposure Start",          .observation),
        Entry("EXPEND",   "Exposure End",            .observation),
        Entry("EXPTIME",  "Exposure Time",           .observation, unit: "s"),
        Entry("EXPOSURE", "Exposure Time",           .observation, unit: "s"),
        Entry("DARKTIME", "Dark Time",               .observation, unit: "s"),
        Entry("LIVETIME", "Live Time",               .observation, unit: "s"),
        Entry("IMAGETYP", "Frame Type",              .observation),
        Entry("FRAME",    "Frame Type",              .observation),
        Entry("FRAMETYP", "Frame Type",              .observation),
        Entry("FILTER",   "Filter",                  .observation),
        Entry("OBSERVER", "Observer",                .observation),
        Entry("TIME-SRC", "Time Source",             .observation),

        // Telescope & Optics
        Entry("TELESCOP", "Telescope",               .telescope),
        Entry("TELID",    "Telescope ID",            .telescope),
        Entry("FOCALLEN", "Focal Length",            .telescope, unit: "mm", precision: 0),
        Entry("APTDIA",   "Aperture Diameter",       .telescope, unit: "mm", precision: 0),
        Entry("FOCUSPOS", "Focuser Position",        .telescope, unit: "steps"),
        Entry("FOCUSTEM", "Focuser Temperature",     .telescope, unit: "°C", precision: 1),
        Entry("PIERSIDE", "Pier Side",               .telescope),

        // Camera
        Entry("INSTRUME", "Camera",                  .camera),
        Entry("IMAGERID", "Camera ID",               .camera),
        Entry("GAIN",     "Gain",                    .camera),
        Entry("EGAIN",    "Electron Gain",           .camera, unit: "e⁻/ADU", precision: 3),
        Entry("OFFSET",   "Offset",                  .camera),
        Entry("AOFFSET",  "Analog Offset",           .camera),
        Entry("CCD-TEMP", "Sensor Temperature",      .camera, unit: "°C", precision: 1),
        Entry("CCD-TMIN", "Sensor Temperature (min)", .camera, unit: "°C", precision: 1),
        Entry("CCD-TMAX", "Sensor Temperature (max)", .camera, unit: "°C", precision: 1),
        Entry("XBINNING", "Binning X",               .camera),
        Entry("YBINNING", "Binning Y",               .camera),
        Entry("XPIXSZ",   "Pixel Size X",            .camera, unit: "µm", precision: 2),
        Entry("YPIXSZ",   "Pixel Size Y",            .camera, unit: "µm", precision: 2),
        Entry("PIXSIZE1", "Pixel Size X",            .camera, unit: "µm", precision: 2),
        Entry("PIXSIZE2", "Pixel Size Y",            .camera, unit: "µm", precision: 2),
        Entry("BAYERPAT", "Bayer Pattern",           .camera),

        // Site & Conditions
        Entry("OBSERVAT", "Observatory",             .site),
        Entry("SITELAT",  "Site Latitude",           .site, precision: 5),
        Entry("SITELONG", "Site Longitude",          .site, precision: 5),
        Entry("GPS-LAT",  "GPS Latitude",            .site, unit: "°", precision: 5),
        Entry("GPS-LON",  "GPS Longitude",           .site, unit: "°", precision: 5),
        Entry("OBJCTALT", "Altitude",                .site, unit: "°", precision: 2),
        Entry("OBJCTAZ",  "Azimuth",                 .site, unit: "°", precision: 2),
        Entry("AIRMASS",  "Airmass",                 .site, precision: 3),

        // Astrometric Solution (plate scale + WCS)
        Entry("SCALE",    "Image Scale",             .astrometry, unit: "″/px", precision: 3),
        Entry("PIXSCALE", "Pixel Scale",             .astrometry, unit: "″/px", precision: 3),
        Entry("SECPIX1",  "Plate Scale X",           .astrometry, unit: "″/px", precision: 3),
        Entry("SECPIX2",  "Plate Scale Y",           .astrometry, unit: "″/px", precision: 3),
        Entry("RADECSYS", "Coordinate Frame",        .astrometry),
        Entry("CTYPE1",   "WCS Projection (axis 1)", .astrometry),
        Entry("CTYPE2",   "WCS Projection (axis 2)", .astrometry),
        Entry("CRVAL1",   "Reference RA",            .astrometry, unit: "°", precision: 5),
        Entry("CRVAL2",   "Reference Dec",           .astrometry, unit: "°", precision: 5),
        Entry("CRPIX1",   "Reference Pixel X",       .astrometry, unit: "px", precision: 2),
        Entry("CRPIX2",   "Reference Pixel Y",       .astrometry, unit: "px", precision: 2),
        Entry("CDELT1",   "Pixel Scale (axis 1)",    .astrometry, unit: "°/px"),
        Entry("CDELT2",   "Pixel Scale (axis 2)",    .astrometry, unit: "°/px"),
        Entry("CROTA1",   "Rotation (axis 1)",       .astrometry, unit: "°", precision: 2),
        Entry("CROTA2",   "Rotation (axis 2)",       .astrometry, unit: "°", precision: 2),
        Entry("CUNIT1",   "WCS Unit (axis 1)",       .astrometry),
        Entry("CUNIT2",   "WCS Unit (axis 2)",       .astrometry),
        Entry("PC1_1",    "WCS Matrix [1,1]",        .astrometry),
        Entry("PC1_2",    "WCS Matrix [1,2]",        .astrometry),
        Entry("PC2_1",    "WCS Matrix [2,1]",        .astrometry),
        Entry("PC2_2",    "WCS Matrix [2,2]",        .astrometry),

        // Processing & Stacking
        Entry("PROGRAM",  "Acquisition Software",    .processing),
        Entry("PROC",     "Processing Software",     .processing),
        Entry("SWCREATE", "Created By",              .processing),
        Entry("PIPELINE", "Pipeline",                .processing),
        Entry("NFRAMES",  "Combined Frames",         .processing),
        Entry("STACKED",  "Stacked",                 .processing),
        Entry("STACKCNT", "Stacked Frames",          .processing),
        Entry("STCKMET",  "Stacking Method",         .processing),
        Entry("STCKNORM", "Stack Normalization",     .processing),
        Entry("STCKREJO", "Stack Rejection",         .processing),
        Entry("STCKRJLO", "Rejection Threshold (low)",  .processing, unit: "σ", precision: 1),
        Entry("STCKRJHI", "Rejection Threshold (high)", .processing, unit: "σ", precision: 1),

        // Quality
        Entry("FWHM",     "FWHM",                    .quality, precision: 1),
        // SKY_BKG is written as a normalised 0–1 level, not ADU — no fixed precision.
        Entry("SKY_BKG",  "Sky Background",          .quality),

        // File Structure
        Entry("SIMPLE",   "Standard FITS",           .file),
        Entry("BITPIX",   "Bits per Pixel",          .file),
        Entry("NAXIS",    "Axes",                    .file),
        Entry("NAXIS1",   "Width",                   .file, unit: "px"),
        Entry("NAXIS2",   "Height",                  .file, unit: "px"),
        Entry("NAXIS3",   "Planes",                  .file),
        Entry("EXTEND",   "Extensions Allowed",      .file),
        Entry("BZERO",    "Zero Offset (BZERO)",     .file, precision: 0),
        Entry("BSCALE",   "Scale Factor (BSCALE)",   .file),
        Entry("ROWORDER", "Row Order",               .file),
        Entry("DATE",     "File Date",               .file),
    ]
}
