import SwiftUI
import AstroKit

// MARK: - AngleLabel

/// Displays a radian angle as formatted attributed text.
///
/// For `.hms` format the `h`, `m`, `s` unit symbols appear raised as superscript.
/// For `.mas` / `.µas` the unit suffix is dimmed with `.secondary` foreground color.
/// For DMS formats the unit symbols appear at normal size.
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

#Preview("Proper motion (mas)") {
    AngleLabel(
        1234.567 * .pi / (180.0 * 3_600_000.0),
        formatter: .init(format: .mas, precision: 4)
    )
    .padding()
}
