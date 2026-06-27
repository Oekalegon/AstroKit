import Testing
import SwiftUI
import AstroKit
import AstroKitUI

@Suite("AngleLabel")
struct AngleLabelTests {

    // Sirius: RA 6h 45m 08.9s
    let siriusRA  = (6.0 + 45.0/60 + 8.9/3600) * 15 * .pi / 180
    // Sirius: Dec −16° 42′ 58.0″
    let siriusDec = -(16.0 + 42.0/60 + 58.0/3600) * .pi / 180

    // MARK: - attributedString(from:)

    @Test("attributedString: HMS h/m/s units have positive baseline offset")
    func hmsUnitsAreSuperscript() {
        let f   = AngleFormatter(format: .hms, precision: 3)
        let as_ = f.attributedString(from: siriusRA)
        let raised = as_.runs.filter { $0.swiftUI.baselineOffset.map { $0 > 0 } ?? false }
        #expect(raised.count == 3, "Expected 3 raised runs (h, m, s), got \(raised.count)")
    }

    @Test("attributedString: HMS precision=4 — decimal digits after 's' carry no baseline offset")
    func hmsDecimalDigitsAreNotRaised() {
        let f   = AngleFormatter(format: .hms, precision: 4)
        let as_ = f.attributedString(from: siriusRA)
        let raised = as_.runs.filter { $0.swiftUI.baselineOffset.map { $0 > 0 } ?? false }
        #expect(raised.count == 3, "Decimal digits must not be raised; got \(raised.count) raised runs")
    }

    @Test("attributedString: DMS units have no baseline offset")
    func dmsUnitsAreNotSuperscript() {
        let f   = AngleFormatter(format: .sdms, precision: 3)
        let as_ = f.attributedString(from: siriusDec)
        let raised = as_.runs.filter { $0.swiftUI.baselineOffset.map { $0 > 0 } ?? false }
        #expect(raised.isEmpty, "DMS units must not be raised")
    }

    @Test("attributedString: mas returns plain string with no raised runs")
    func masIsPlain() {
        let val = 1234.5 * .pi / (180.0 * 3_600_000.0)
        let f   = AngleFormatter(format: .mas, precision: 3)
        let as_ = f.attributedString(from: val)
        let raised = as_.runs.filter { $0.swiftUI.baselineOffset.map { $0 > 0 } ?? false }
        #expect(raised.isEmpty)
    }

    @Test("attributedString: mas unit suffix has secondary foreground color")
    func masUnitSuffixIsSecondary() {
        let val = 1234.5 * .pi / (180.0 * 3_600_000.0)
        let f   = AngleFormatter(format: .mas, precision: 3)
        let as_ = f.attributedString(from: val)
        let colored = as_.runs.filter { $0.swiftUI.foregroundColor != nil }
        #expect(colored.count == 1, "Expected 1 colored run (unit suffix), got \(colored.count)")
        #expect(colored.first?.swiftUI.foregroundColor == Color.secondary)
    }

    @Test("attributedString: µas unit suffix has secondary foreground color")
    func µasUnitSuffixIsSecondary() {
        let val = 12345.0 * .pi / (180.0 * 3_600_000_000.0)
        let f   = AngleFormatter(format: .µas, precision: 2)
        let as_ = f.attributedString(from: val)
        let colored = as_.runs.filter { $0.swiftUI.foregroundColor != nil }
        #expect(colored.count == 1, "Expected 1 colored run (unit suffix), got \(colored.count)")
        #expect(colored.first?.swiftUI.foregroundColor == Color.secondary)
    }

    @Test("attributedString: string content matches format(_:) output for all formats")
    func attributedStringTextMatchesFormat() {
        let angles: [(AngleFormatter, Double)] = [
            (.init(format: .hms,  precision: 4), siriusRA),
            (.init(format: .sdms, precision: 4), siriusDec),
            (.init(format: .dms,  precision: 2), Swift.abs(siriusDec)),
            (.init(format: .mas,  precision: 3), 1234.5 * .pi / (180.0 * 3_600_000.0)),
            (.init(format: .µas,  precision: 2), 12345.0 * .pi / (180.0 * 3_600_000_000.0)),
        ]
        for (f, v) in angles {
            #expect(String(f.attributedString(from: v).characters) == f.format(v),
                    "Format mismatch for \(f.format)")
        }
    }
}
