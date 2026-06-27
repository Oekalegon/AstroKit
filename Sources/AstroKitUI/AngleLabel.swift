import SwiftUI
import AstroKit

// MARK: - AngleFormatter + AttributedString

extension AngleFormatter {
    /// Returns an `AttributedString` version of the formatted angle.
    ///
    /// For `.hms`, the unit symbols `h`, `m`, `s` are rendered as raised superscript
    /// (smaller font, positive baseline offset). All other unit symbols (`°`, `′`, `″`,
    /// `mas`, `µas`) appear at normal size with no baseline shift.
    public func attributedString(from radians: Double) -> AttributedString {
        let plain = format(radians)
        guard format == .hms else { return AttributedString(plain) }
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
    }
}

// MARK: - AngleLabel

/// Displays a radian angle as formatted attributed text.
///
/// For `.hms` format the `h`, `m`, `s` unit symbols appear raised as superscript.
/// For DMS and sub-arc formats the unit symbols appear at normal size.
public struct AngleLabel: View {
    public let radians: Double
    public let formatter: AngleFormatter

    public init(_ radians: Double, formatter: AngleFormatter) {
        self.radians   = radians
        self.formatter = formatter
    }

    public var body: some View {
        Text(formatter.attributedString(from: radians))
    }
}

// MARK: - Previews

#Preview("HMS Sirius RA") {
    AngleLabel(
        (6.0 + 45.0/60 + 8.9/3600) * 15 * .pi / 180,
        formatter: .init(format: .hms, precision: 4)
    )
    .padding()
}

#Preview("SDMS Sirius Dec") {
    AngleLabel(
        -(16.0 + 42.0/60 + 58.0/3600) * .pi / 180,
        formatter: .init(format: .sdms, precision: 3)
    )
    .padding()
}
