import Foundation

/// Stateless helpers for extracting typed values from a FITS header dictionary.
///
/// Shared between processors inside `AstrophotoKit` and the archiving layer in
/// `AstrophotoArchiveKit` so the sexagesimal parsers and timestamp logic live in
/// exactly one place.
public enum FITSHeaderParser {

    // MARK: - Scalar extraction

    public static func doubleValue(_ headers: [String: FITSHeaderValue], keys: [String]) -> Double? {
        for key in keys {
            if let v = headers[key]?.doubleValue { return v }
        }
        return nil
    }

    public static func stringValue(_ headers: [String: FITSHeaderValue], keys: [String]) -> String? {
        for key in keys {
            if let v = headers[key]?.stringValue { return v }
        }
        return nil
    }

    // MARK: - Coordinate resolution

    /// RA in degrees. Tries decimal `RA` first, then sexagesimal `OBJCTRA`.
    public static func resolveRA(_ headers: [String: FITSHeaderValue]) -> Double? {
        if let d = headers["RA"]?.doubleValue { return d }
        if let s = headers["OBJCTRA"]?.stringValue { return parseSexagesimalHours(s) }
        return nil
    }

    /// Dec in degrees. Tries decimal `DEC` first, then sexagesimal `OBJCTDEC`.
    public static func resolveDec(_ headers: [String: FITSHeaderValue]) -> Double? {
        if let d = headers["DEC"]?.doubleValue { return d }
        if let s = headers["OBJCTDEC"]?.stringValue { return parseSexagesimalDegrees(s) }
        return nil
    }

    /// Parses "HH MM SS.ss" or "HH:MM:SS.ss" to decimal degrees (× 15).
    static func parseSexagesimalHours(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " :"))
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let hours = parts[0] + parts[1] / 60 + (parts.count > 2 ? parts[2] / 3600 : 0)
        return hours * 15.0
    }

    /// Parses "±DD MM SS.ss" or "±DD:MM:SS.ss" to decimal degrees.
    static func parseSexagesimalDegrees(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let negative = trimmed.hasPrefix("-")
        let parts = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            .components(separatedBy: CharacterSet(charactersIn: " :"))
            .compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let degrees = parts[0] + parts[1] / 60 + (parts.count > 2 ? parts[2] / 3600 : 0)
        return negative ? -degrees : degrees
    }

    // MARK: - Timestamp

    /// Parses a DATE-OBS / DATE-BEG value to a UTC `Date`.
    ///
    /// Accepts ISO 8601 with timezone (including `Z` and `+HH:MM` suffixes),
    /// bare datetime strings without timezone (treated as UTC), and bare date-only
    /// strings (treated as midnight UTC).
    public static func parseTimestamp(_ headers: [String: FITSHeaderValue]) -> Date? {
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
}
