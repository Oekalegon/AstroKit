extension FrameDiff {
    /// A typed representation of a single pipeline parameter value.
    ///
    /// Pipeline parameters are stored as raw strings in the database. `ParameterValue`
    /// parses them into the most specific type that fits, so numeric parameters like
    /// `"3.0"` and `"3"` compare equal, booleans are recognised as such, and only
    /// values that cannot be interpreted as anything else remain plain strings.
    public enum ParameterValue: Sendable, Equatable, CustomStringConvertible {
        case boolean(Bool)
        case integer(Int)
        case double(Double)
        case string(String)

        /// Parse a raw parameter string into the most specific matching type.
        ///
        /// Priority: `Bool` (only "true"/"false") → `Int` → `Double` → `String`.
        public init(_ raw: String) {
            switch raw.lowercased() {
            case "true":  self = .boolean(true);  return
            case "false": self = .boolean(false); return
            default: break
            }
            if let i = Int(raw)    { self = .integer(i); return }
            if let d = Double(raw) { self = .double(d);  return }
            self = .string(raw)
        }

        /// Human-readable form.
        /// Integers print without a decimal point; doubles trim unnecessary trailing zeros.
        public var description: String {
            switch self {
            case .boolean(let b): return b ? "true" : "false"
            case .integer(let i): return "\(i)"
            case .double(let d):
                // NaN and Inf don't contain "." or "e", so guard them before the %g path
                // to avoid producing "nan.0" / "inf.0".
                if d.isNaN      { return "nan" }
                if d.isInfinite { return d > 0 ? "inf" : "-inf" }
                // Format without trailing zeros, but always show at least one decimal place
                // so it's clear this is a floating-point value.
                let s = String(format: "%g", d)
                return s.contains(".") || s.contains("e") ? s : s + ".0"
            case .string(let s):  return s
            }
        }

        // MARK: Equatable

        public static func == (lhs: ParameterValue, rhs: ParameterValue) -> Bool {
            switch (lhs, rhs) {
            case (.boolean(let l), .boolean(let r)): return l == r
            case (.string(let l),  .string(let r)):  return l == r
            // Numeric cross-type equality: compare as Double so "3" == "3.0".
            case (.integer(let l), .integer(let r)): return l == r
            case (.double(let l),  .double(let r)):  return l == r
            case (.integer(let l), .double(let r)):  return Double(l) == r
            case (.double(let l),  .integer(let r)): return l == Double(r)
            default: return false
            }
        }
    }
}
