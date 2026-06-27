import SwiftUI
import AstroKit

extension AngleFormatter {
    /// Returns an `AttributedString` version of the formatted angle.
    ///
    /// - `.hms`: `h`, `m`, `s` unit symbols are raised as superscript (`.caption2` font,
    ///   `baselineOffset` = 4).
    /// - `.mas` / `.µas`: the unit suffix (`"mas"` / `"µas"`) is styled with `.secondary`
    ///   foreground color so it recedes visually behind the numeric value.
    /// - `.dms` / `.sdms`: returned as plain `AttributedString` with no attribute overrides.
    public func attributedString(from radians: Double) -> AttributedString {
        let plain = format(radians)
        switch format {
        case .hms:
            var supAttrs = AttributeContainer()
            supAttrs.swiftUI.font = .caption2
            supAttrs.swiftUI.baselineOffset = 4
            var result = AttributedString()
            var buffer = ""
            for char in plain {
                if char == "h" || char == "m" || char == "s" {
                    if !buffer.isEmpty { result += AttributedString(buffer); buffer = "" }
                    result += AttributedString(String(char), attributes: supAttrs)
                } else {
                    buffer.append(char)
                }
            }
            if !buffer.isEmpty { result += AttributedString(buffer) }
            return result
        case .mas, .µas:
            guard let spaceIdx = plain.lastIndex(of: " ") else { return AttributedString(plain) }
            var secAttrs = AttributeContainer()
            secAttrs.swiftUI.foregroundColor = Color.secondary
            let numPart  = plain[plain.startIndex...spaceIdx]           // "1234.567 "
            let unitPart = plain[plain.index(after: spaceIdx)...]       // "mas"
            return AttributedString(numPart)
                 + AttributedString(unitPart, attributes: secAttrs)
        case .dms, .sdms:
            return AttributedString(plain)
        }
    }
}
