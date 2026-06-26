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
        switch format {
        case .hms:
            return attributedHMS(radians)
        case .dms, .sdms:
            return attributedDMS(radians)
        case .mas:
            return AttributedString(format(radians))
        case .µas:
            return AttributedString(format(radians))
        }
    }

    private func attributedHMS(_ radians: Double) -> AttributedString {
        let twoPi = 2.0 * Double.pi
        let norm  = (radians.truncatingRemainder(dividingBy: twoPi) + twoPi)
                        .truncatingRemainder(dividingBy: twoPi)
        return attributedSexagesimal(norm * (12.0 / .pi),
                                     u1: "h", u2: "m", u3: "s",
                                     primaryWidth: 2, superscriptUnits: true)
    }

    private func attributedDMS(_ radians: Double) -> AttributedString {
        var result = AttributedString()
        if requiresSign {
            result += AttributedString(radians < 0 ? "-" : "+")
        }
        let deg = Swift.abs(radians) * (180.0 / .pi)
        result += attributedSexagesimal(deg,
                                        u1: "°", u2: "′", u3: "″",
                                        primaryWidth: requiresSign ? 2 : 3,
                                        superscriptUnits: false)
        return result
    }

    private func attributedSexagesimal(_ value: Double, u1: String, u2: String, u3: String,
                                        primaryWidth: Int, superscriptUnits: Bool) -> AttributedString {
        var supAttrs = AttributeContainer()
        if superscriptUnits {
            supAttrs.swiftUI.font = .caption2
            supAttrs.swiftUI.baselineOffset = 4
        }

        func d(_ s: String) -> AttributedString { AttributedString(s) }
        func u(_ s: String) -> AttributedString { AttributedString(s, attributes: supAttrs) }

        let totalSec = value * 3600.0

        switch startComponent {
        case .primary:
            let decPlaces = max(0, precision - 3)
            if decPlaces == 0 {
                let ts = Int((totalSec * 1_000_000.0).rounded() / 1_000_000.0)
                let c1 = ts / 3600;  let c2 = (ts % 3600) / 60;  let c3 = ts % 60
                let p1 = String(format: "%0\(primaryWidth)d", c1)
                switch precision {
                case 1:
                    return d(p1) + u(u1)
                case 2:
                    return d(p1) + u(u1) + d(String(format: "%02d", c2)) + u(u2)
                default:
                    return d(p1) + u(u1)
                         + d(String(format: "%02d", c2)) + u(u2)
                         + d(String(format: "%02d", c3)) + u(u3)
                }
            } else {
                let scale = pow(10.0, Double(decPlaces))
                let ts    = (totalSec * scale).rounded() / scale
                let its   = Int(ts);  let frac = ts - Double(its)
                let c1 = its / 3600;  let c2 = (its % 3600) / 60;  let c3 = its % 60
                let dec = String(format: "%0\(decPlaces)d", Int((frac * scale).rounded()))
                return d(String(format: "%0\(primaryWidth)d", c1)) + u(u1)
                     + d(String(format: "%02d", c2)) + u(u2)
                     + d(String(format: "%02d", c3)) + u(u3)
                     + d(dec)
            }

        case .secondary:
            let decPlaces = max(0, precision - 2)
            if decPlaces == 0 {
                let totalSecI = Int((totalSec * 1_000_000.0).rounded() / 1_000_000.0)
                let mins = totalSecI / 60;  let secs = totalSecI % 60
                switch precision {
                case 1:
                    return d("\(mins)") + u(u2)
                default:
                    return d("\(mins)") + u(u2) + d(String(format: "%02d", secs)) + u(u3)
                }
            } else {
                let scale = pow(10.0, Double(decPlaces))
                let ts    = (totalSec * scale).rounded() / scale
                let its   = Int(ts);  let frac = ts - Double(its)
                let mins  = its / 60;  let secs = its % 60
                let dec = String(format: "%0\(decPlaces)d", Int((frac * scale).rounded()))
                return d("\(mins)") + u(u2) + d(String(format: "%02d", secs)) + u(u3) + d(dec)
            }

        case .tertiary:
            let decPlaces = max(0, precision - 1)
            if decPlaces == 0 {
                return d("\(Int((totalSec * 1_000_000.0).rounded() / 1_000_000.0))") + u(u3)
            } else {
                let scale = pow(10.0, Double(decPlaces))
                let ts    = (totalSec * scale).rounded() / scale
                let its   = Int(ts);  let frac = ts - Double(its)
                let dec = String(format: "%0\(decPlaces)d", Int((frac * scale).rounded()))
                return d("\(its)") + u(u3) + d(dec)
            }
        }
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
