import Foundation

// MARK: - AngleFormatter

/// Formats a radian angle as a human-readable sexagesimal string.
///
/// **Format** controls the notation:
/// - `.hms`  — Hours–minutes–seconds; wraps to [0 h, 24 h). No sign.
/// - `.dms`  — Degrees–arcminutes–arcseconds; sign determined by `requiresSign`.
/// - `.sdms` — Signed degrees–arcminutes–arcseconds; `+`/`-` prefix. Equivalent to
///             `.dms` + `requiresSign = true`; retained for source compatibility.
/// - `.mas`  — Milliarcseconds; decimal with space: `"1234.567 mas"`.
/// - `.µas`  — Microarcseconds; decimal with space: `"1234567.890 µas"`.
///
/// **StartComponent** controls which unit appears first (not applicable for `.mas`/`.µas`):
/// - `.primary`   (default) — start from hours / degrees
/// - `.secondary`           — start from minutes / arcminutes
/// - `.tertiary`            — start from seconds / arcseconds
///
/// **Precision** controls depth and decimal places, measured from `startComponent`:
///
/// | precision | .primary HMS      | .secondary HMS | .tertiary HMS |
/// |-----------|-------------------|----------------|---------------|
/// | 1         | `06h`             | `45m`          | `08s`         |
/// | 2         | `06h45m`          | `45m08s`       | `08s9`        |
/// | 3         | `06h45m08s`       | `45m08s9`      | `08s93`       |
/// | 4         | `06h45m08s9`      | `45m08s93`     | `08s934`      |
///
/// For `.mas`/`.µas`, `precision` controls decimal places (1 = integer only, 2 = 1 d.p., etc.).
///
/// The unit symbol acts as the decimal separator for the last sexagesimal component:
/// `08s9` rather than `08.9s`.
public struct AngleFormatter: Sendable, Codable, Hashable {

    // MARK: - Nested types

    /// The output notation.
    public enum Format: Sendable, Codable, Hashable {
        /// Hours–minutes–seconds. Full circle = 24 h. No sign.
        case hms
        /// Degrees–arcminutes–arcseconds. Sign controlled by `requiresSign`.
        case dms
        /// Signed degrees–arcminutes–arcseconds. `+`/`-` prefix (for declination).
        /// Equivalent to `.dms` + `requiresSign = true`.
        case sdms
        /// Milliarcseconds. Decimal with space: `"1234.567 mas"`.
        case mas
        /// Microarcseconds. Decimal with space: `"1234567.890 µas"`.
        case µas
    }

    /// Which sexagesimal unit to show first.
    public enum StartComponent: Sendable, Codable, Hashable {
        /// Begin with hours (HMS) or degrees (DMS/SDMS). Default.
        case primary
        /// Begin with minutes (HMS) or arcminutes (DMS/SDMS).
        case secondary
        /// Begin with seconds (HMS) or arcseconds (DMS/SDMS).
        case tertiary
    }

    // MARK: - Properties

    public var format: Format
    public var startComponent: StartComponent
    public var precision: Int
    /// Whether a `+`/`-` sign prefix is required.
    /// Defaults to `true` for `.sdms` and `false` for all other formats.
    /// Applies to `.dms` and `.sdms` only; ignored for `.hms`, `.mas`, and `.µas`.
    public var requiresSign: Bool

    // MARK: - Initialisers

    public init(format: Format, precision: Int = 4, startComponent: StartComponent = .primary,
                requiresSign: Bool? = nil) {
        self.format         = format
        self.startComponent = startComponent
        self.precision      = max(1, precision)
        self.requiresSign   = requiresSign ?? (format == .sdms)
    }

    // MARK: - Public API

    /// Convert `radians` to a formatted sexagesimal string.
    public func format(_ radians: Double) -> String {
        switch format {
        case .hms:        return formatHMS(radians)
        case .dms, .sdms: return formatDMS(radians)
        case .mas:        return formatSubArc(radians, scale: 180.0 / .pi * 3_600_000.0,     unit: "mas")
        case .µas:        return formatSubArc(radians, scale: 180.0 / .pi * 3_600_000_000.0, unit: "µas")
        }
    }

    /// Alias for `format(_:)` for callers who prefer the `string(from:)` pattern.
    public func string(from radians: Double) -> String { format(radians) }

    /// Parse a sexagesimal string back to radians.
    ///
    /// The parser recognises whichever unit symbols are present in the string;
    /// `startComponent` is ignored (the symbols are self-describing).
    /// The unit symbol after the last integer component acts as the decimal
    /// separator, matching the output of `format(_:)`.
    ///
    /// Returns `nil` when the string contains no recognised unit symbols or
    /// cannot be parsed.
    public func parse(_ string: String) -> Double? {
        switch format {
        case .hms:
            return AngleFormatter.parseUnits(string, u1: "h", u2: "m", u3: "s",
                                             scale: .pi / 12.0, signed: false)
        case .dms, .sdms:
            return AngleFormatter.parseUnits(string, u1: "°", u2: "′", u3: "″",
                                             scale: .pi / 180.0, signed: requiresSign)
        case .mas:
            return parseSubArc(string, unit: "mas", scale: .pi / (180.0 * 3_600_000.0))
        case .µas:
            return parseSubArc(string, unit: "µas", scale: .pi / (180.0 * 3_600_000_000.0))
        }
    }

    /// Alias for `parse(_:)` for callers who prefer the `double(from:)` pattern.
    public func double(from string: String) -> Double? { parse(string) }

    // MARK: - Private: sub-arc formatting

    private func formatSubArc(_ radians: Double, scale: Double, unit: String) -> String {
        let value = radians * scale
        let decPlaces = max(0, precision - 1)
        if decPlaces == 0 {
            return "\(Int(value.rounded())) \(unit)"
        } else {
            return String(format: "%.\(decPlaces)f \(unit)", value)
        }
    }

    private func parseSubArc(_ string: String, unit: String, scale: Double) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(" \(unit)") else { return nil }
        let numStr = String(trimmed.dropLast(unit.count + 1))
        guard let value = Double(numStr) else { return nil }
        return value * scale
    }

    // MARK: - Private parsing

    private static func parseUnits(_ string: String, u1: Character, u2: Character, u3: Character,
                                    scale: Double, signed: Bool) -> Double? {
        var s = string
        var sign = 1.0

        if signed {
            if s.hasPrefix("-") { sign = -1.0; s.removeFirst() }
            else if s.hasPrefix("+") { s.removeFirst() }
        }

        // Require at least one unit symbol — reject plain numbers and empty strings.
        guard s.contains(u1) || s.contains(u2) || s.contains(u3) else { return nil }

        var primary = 0.0, secondary = 0.0, tertiary = 0.0

        if let idx = s.firstIndex(of: u1) {
            guard let val = Double(s[s.startIndex..<idx]) else { return nil }
            primary = val
            s = String(s[s.index(after: idx)...])
        }

        if let idx = s.firstIndex(of: u2) {
            guard let val = Double(s[s.startIndex..<idx]) else { return nil }
            secondary = val
            s = String(s[s.index(after: idx)...])
        }

        if let idx = s.firstIndex(of: u3) {
            // The unit symbol is the decimal separator: "08s9" → integer=8, decimal=0.9
            guard let intVal = Int(s[s.startIndex..<idx]) else { return nil }
            let decStr = String(s[s.index(after: idx)...])
            let decVal: Double
            if decStr.isEmpty {
                decVal = 0.0
            } else {
                guard let digits = Double(decStr) else { return nil }
                decVal = digits / pow(10.0, Double(decStr.count))
            }
            tertiary = Double(intVal) + decVal
        }

        return sign * (primary + secondary / 60.0 + tertiary / 3600.0) * scale
    }

    // MARK: - Private formatting

    private func formatHMS(_ radians: Double) -> String {
        let twoPi = 2.0 * Double.pi
        let norm  = (radians.truncatingRemainder(dividingBy: twoPi) + twoPi)
                        .truncatingRemainder(dividingBy: twoPi)
        return sexagesimal(norm * (12.0 / .pi), u1: "h", u2: "m", u3: "s", primaryWidth: 2)
    }

    private func formatDMS(_ radians: Double) -> String {
        let sign = requiresSign ? (radians < 0 ? "-" : "+") : ""
        let deg  = Swift.abs(radians) * (180.0 / .pi)
        // Unsigned longitude: 3-digit degrees (0–359°). Signed declination: 2-digit (±90°).
        return sign + sexagesimal(deg, u1: "°", u2: "′", u3: "″", primaryWidth: requiresSign ? 2 : 3)
    }

    /// Entry point: `value` is in hours (HMS) or degrees (DMS/SDMS), always non-negative.
    /// `primaryWidth` is the zero-pad width for the first component when startComponent == .primary.
    private func sexagesimal(_ value: Double, u1: String, u2: String, u3: String,
                              primaryWidth: Int) -> String {
        let totalSec = value * 3600.0   // total arcseconds / seconds

        switch startComponent {

        case .primary:
            // 3 possible components. Integer threshold at precision 3.
            // precision 1 → just c1; 2 → c1+c2; 3 → c1+c2+c3 (integer); 4+ → + decimal places
            let decPlaces = max(0, precision - 3)
            if decPlaces == 0 {
                let ts = Int((totalSec * 1_000_000.0).rounded() / 1_000_000.0)
                let c1 = ts / 3600;  let c2 = (ts % 3600) / 60;  let c3 = ts % 60
                let p1 = String(format: "%0\(primaryWidth)d", c1)
                let p2 = String(format: "%02d", c2)
                let p3 = String(format: "%02d", c3)
                switch precision {
                case 1:  return "\(p1)\(u1)"
                case 2:  return "\(p1)\(u1)\(p2)\(u2)"
                default: return "\(p1)\(u1)\(p2)\(u2)\(p3)\(u3)"
                }
            } else {
                // Round in total-seconds space to handle 59.99 s → 60 s carry-overs.
                let scale = pow(10.0, Double(decPlaces))
                let ts    = (totalSec * scale).rounded() / scale
                let its   = Int(ts);  let frac = ts - Double(its)
                let c1 = its / 3600;  let c2 = (its % 3600) / 60;  let c3 = its % 60
                let dec = String(format: "%0\(decPlaces)d", Int((frac * scale).rounded()))
                return "\(String(format: "%0\(primaryWidth)d", c1))\(u1)"
                     + "\(String(format: "%02d", c2))\(u2)"
                     + "\(String(format: "%02d", c3))\(u3)\(dec)"
            }

        case .secondary:
            // 2 possible components: minutes + seconds.
            // precision 1 → just minutes (integer); 2 → +integer seconds; 3+ → + decimal places
            let decPlaces = max(0, precision - 2)
            if decPlaces == 0 {
                // Round to the nearest microsecond first to avoid floating-point drift
                // (e.g. 133.0/3600*3600 → 132.9999... would truncate to 132).
                let totalSecI = Int((totalSec * 1_000_000.0).rounded() / 1_000_000.0)
                let mins  = totalSecI / 60
                let secs  = totalSecI % 60
                switch precision {
                case 1:  return "\(mins)\(u2)"
                default: return "\(mins)\(u2)\(String(format: "%02d", secs))\(u3)"
                }
            } else {
                let scale = pow(10.0, Double(decPlaces))
                let ts    = (totalSec * scale).rounded() / scale
                let its   = Int(ts);  let frac = ts - Double(its)
                let mins  = its / 60;  let secs = its % 60
                let dec = String(format: "%0\(decPlaces)d", Int((frac * scale).rounded()))
                return "\(mins)\(u2)\(String(format: "%02d", secs))\(u3)\(dec)"
            }

        case .tertiary:
            // 1 component: seconds only.
            // precision 1 → integer seconds; 2+ → (precision − 1) decimal places
            let decPlaces = max(0, precision - 1)
            if decPlaces == 0 {
                return "\(Int((totalSec * 1_000_000.0).rounded() / 1_000_000.0))\(u3)"
            } else {
                let scale = pow(10.0, Double(decPlaces))
                let ts    = (totalSec * scale).rounded() / scale
                let its   = Int(ts);  let frac = ts - Double(its)
                let dec = String(format: "%0\(decPlaces)d", Int((frac * scale).rounded()))
                return "\(its)\(u3)\(dec)"
            }
        }
    }
}

// MARK: - ParseableFormatStyle

extension AngleFormatter: FormatStyle {
    public typealias FormatInput  = Double
    public typealias FormatOutput = String
}

extension AngleFormatter: ParseableFormatStyle {
    public var parseStrategy: AngleParseStrategy { AngleParseStrategy(formatter: self) }
}

/// `ParseStrategy` that inverts `AngleFormatter.format(_:)` back to radians.
public struct AngleParseStrategy: ParseStrategy, Sendable {
    public let formatter: AngleFormatter

    public func parse(_ value: String) throws -> Double {
        guard let radians = formatter.parse(value) else {
            throw CocoaError(.formatting)
        }
        return radians
    }
}
