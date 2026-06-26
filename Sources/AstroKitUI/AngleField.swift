import SwiftUI
import AstroKit

// MARK: - AngleField

/// A segmented input control for editing an angle expressed in radians.
///
/// The field decomposes the angle into up to three editable sub-fields (primary /
/// secondary / tertiary) separated by non-editable unit labels, matching the layout
/// of `AngleFormatter`:
///
/// - `.hms`  — `[HH]ʰ [MM]ᵐ [SS]ˢ` (h/m/s raised as superscript)
/// - `.dms`  — `[DDD]° [MM]′ [SS]″`
/// - `.sdms` — `[±][DD]° [MM]′ [SS]″`
/// - `.mas`  — `[NNNNN] mas` (single integer + optional decimal)
/// - `.µas`  — `[NNNNN] µas`
///
/// The number of visible sub-fields is driven by `formatter.precision`:
/// - precision 1 → primary only
/// - precision 2 → primary + secondary
/// - precision 3 → primary + secondary + tertiary (integer)
/// - precision 4+ → tertiary is shown with `precision − 3` fractional digits
///
/// **Interaction model**
/// - Typing digits fills the focused sub-field. After the maximum number of digits
///   has been entered, focus automatically advances to the next sub-field.
/// - Left/right arrow keys always move focus between sub-fields.
/// - Up/down arrow keys increment or decrement the focused sub-field (with clamping
///   for hours/degrees and wrapping for minutes/seconds).
/// - Backspace that empties a non-first sub-field returns focus to the previous one.
/// - The sign toggle button appears before the primary sub-field whenever
///   `formatter.requiresSign` is true.
public struct AngleField: View {

    @Binding private var radians: Double
    private let formatter: AngleFormatter

    // MARK: State

    @State private var isNegative = false
    @State private var primary    = ""
    @State private var secondary  = ""
    @State private var tertiary   = ""
    @State private var decimal    = ""
    @State private var lastComposed: Double = -.infinity

    @FocusState private var focus: Segment?

    private enum Segment: Hashable {
        case primary, secondary, tertiary, decimal
    }

    // MARK: Init

    public init(_ radians: Binding<Double>, formatter: AngleFormatter) {
        self._radians  = radians
        self.formatter = formatter
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 0) {
            if formatter.requiresSign {
                Button(isNegative ? "−" : "+") { isNegative.toggle(); compose() }
                    .buttonStyle(.plain)
                    .frame(width: 14)
            }
            if isSubArc {
                subArcBody
            } else {
                sexagesimalBody
            }
        }
        .font(.body.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .onAppear { decompose(radians) }
        .onChange(of: radians) { _, new in
            guard abs(new - lastComposed) > 1e-15 else { return }
            decompose(new)
        }
        .onKeyPress(.leftArrow)  { moveFocus(by: -1) }
        .onKeyPress(.rightArrow) { moveFocus(by: +1) }
        .onKeyPress(.upArrow)    { nudge(+1) }
        .onKeyPress(.downArrow)  { nudge(-1) }
    }

    // MARK: - Sub-views

    @ViewBuilder private var sexagesimalBody: some View {
        segmentField($primary, maxLength: primaryWidth, segment: .primary)
        unitLabel(unit1, superscript: isHMS)
        if showSecondary {
            segmentField($secondary, maxLength: 2, segment: .secondary)
            unitLabel(unit2, superscript: isHMS)
        }
        if showTertiary {
            segmentField($tertiary, maxLength: 2, segment: .tertiary)
            if showDecimal {
                segmentField($decimal, maxLength: decimalCount, segment: .decimal)
            }
            unitLabel(unit3, superscript: isHMS)
        }
    }

    @ViewBuilder private var subArcBody: some View {
        let decCount = max(0, formatter.precision - 1)
        segmentField($primary, maxLength: 10, segment: .primary)
        if decCount > 0 {
            Text(".").padding(.horizontal, 1)
            segmentField($decimal, maxLength: decCount, segment: .decimal)
        }
        Text(" \(unit1)")
            .foregroundStyle(.secondary)
    }

    private func segmentField(
        _ binding: Binding<String>,
        maxLength: Int,
        segment: Segment
    ) -> some View {
        let isActive = focus == segment
        return ZStack {
            // Hidden text drives the minimum width so the field doesn't shrink when empty.
            Text(String(repeating: "0", count: max(1, maxLength)))
                .hidden()
            TextField("", text: binding)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($focus, equals: segment)
                .onChange(of: binding.wrappedValue) { old, new in
                    onSegmentChange(binding, segment: segment, old: old, new: new, maxLength: maxLength)
                }
        }
        .fixedSize()
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func unitLabel(_ text: String, superscript sup: Bool) -> some View {
        Text(text)
            .font(sup ? .caption2 : .body.monospacedDigit())
            .baselineOffset(sup ? 4 : 0)
    }

    // MARK: - Change handling

    private func onSegmentChange(
        _ binding: Binding<String>,
        segment: Segment,
        old: String,
        new: String,
        maxLength: Int
    ) {
        let digits  = String(new.filter(\.isNumber))
        let limited = String(digits.prefix(maxLength))
        // Write back only if filtering changed the value (prevents infinite loop).
        if binding.wrappedValue != limited { binding.wrappedValue = limited }
        // Auto-advance when the sub-field is full.
        if limited.count == maxLength, let next = nextSegment(after: segment) {
            focus = next
        }
        // Backspace that emptied this sub-field → retreat to previous.
        if limited.isEmpty && !old.isEmpty, let prev = prevSegment(before: segment) {
            focus = prev
        }
        compose()
    }

    // MARK: - Arrow-key navigation

    @discardableResult
    private func moveFocus(by delta: Int) -> KeyPress.Result {
        let order = segmentOrder
        guard let current = focus,
              let idx = order.firstIndex(of: current) else { return .ignored }
        let next = idx + delta
        guard order.indices.contains(next) else { return .ignored }
        focus = order[next]
        return .handled
    }

    @discardableResult
    private func nudge(_ delta: Int) -> KeyPress.Result {
        switch focus {
        case .primary:
            let val = clampedPrimary((Int(primary) ?? 0) + delta)
            primary = String(format: "%0\(primaryWidth)d", val)
        case .secondary:
            let val = ((Int(secondary) ?? 0) + delta + 60) % 60
            secondary = String(format: "%02d", val)
        case .tertiary:
            let val = ((Int(tertiary) ?? 0) + delta + 60) % 60
            tertiary = String(format: "%02d", val)
        case .decimal, .none:
            return .ignored
        }
        compose()
        return .handled
    }

    private func clampedPrimary(_ val: Int) -> Int {
        switch formatter.format {
        case .hms:        return min(max(val, 0), 23)
        case .dms, .sdms: return min(max(val, 0), formatter.requiresSign ? 90 : 359)
        default:          return max(val, 0)
        }
    }

    // MARK: - Segment ordering

    private var segmentOrder: [Segment] {
        var order: [Segment] = [.primary]
        if showSecondary { order.append(.secondary) }
        if showTertiary  { order.append(.tertiary) }
        if showDecimal || (isSubArc && formatter.precision > 1) { order.append(.decimal) }
        return order
    }

    private func nextSegment(after segment: Segment) -> Segment? {
        let order = segmentOrder
        guard let idx = order.firstIndex(of: segment), idx + 1 < order.count else { return nil }
        return order[idx + 1]
    }

    private func prevSegment(before segment: Segment) -> Segment? {
        let order = segmentOrder
        guard let idx = order.firstIndex(of: segment), idx > 0 else { return nil }
        return order[idx - 1]
    }

    // MARK: - Compose / decompose

    private func compose() {
        let pVal = Double(primary)   ?? 0
        let sVal = Double(secondary) ?? 0
        let tVal = Double(tertiary)  ?? 0
        let dFrac = decimal.isEmpty ? 0.0
                  : (Double(decimal) ?? 0) / pow(10.0, Double(decimal.count))
        let tWithDec = tVal + dFrac

        var result: Double
        switch formatter.format {
        case .hms:
            result = (pVal + sVal / 60.0 + tWithDec / 3600.0) * .pi / 12.0
        case .dms, .sdms:
            result = (pVal + sVal / 60.0 + tWithDec / 3600.0) * .pi / 180.0
        case .mas:
            let v = pVal + dFrac
            result = v * .pi / (180.0 * 3_600_000.0)
        case .µas:
            let v = pVal + dFrac
            result = v * .pi / (180.0 * 3_600_000_000.0)
        }
        if isNegative { result = -result }
        lastComposed = result
        radians = result
    }

    private func decompose(_ value: Double) {
        isNegative = value < 0 && formatter.requiresSign
        let absVal = Swift.abs(value)
        switch formatter.format {
        case .hms:
            let totalSec = absVal * (12.0 / .pi) * 3600.0
            setComponents(totalSec: totalSec)
        case .dms, .sdms:
            let totalSec = absVal * (180.0 / .pi) * 3600.0
            setComponents(totalSec: totalSec)
        case .mas:
            setSubArc(absVal * 180.0 / .pi * 3_600_000.0)
        case .µas:
            setSubArc(absVal * 180.0 / .pi * 3_600_000_000.0)
        }
        lastComposed = value
    }

    private func setComponents(totalSec: Double) {
        let decCount = max(0, formatter.precision - 3)
        let scale    = pow(10.0, Double(decCount))
        let rounded  = (totalSec * scale).rounded() / scale
        let its      = Int(rounded)
        let c1 = its / 3600;  let c2 = (its % 3600) / 60;  let c3 = its % 60
        primary   = String(format: "%0\(primaryWidth)d", c1)
        secondary = String(format: "%02d", c2)
        tertiary  = String(format: "%02d", c3)
        if decCount > 0 {
            let frac = rounded - Double(its)
            decimal = String(format: "%0\(decCount)d", Int((frac * scale).rounded()))
        } else {
            decimal = ""
        }
    }

    private func setSubArc(_ value: Double) {
        let decCount = max(0, formatter.precision - 1)
        let scale    = pow(10.0, Double(decCount))
        let rounded  = (value * scale).rounded() / scale
        let intPart  = Int(rounded)
        primary = "\(intPart)"
        if decCount > 0 {
            let frac = rounded - Double(intPart)
            decimal = String(format: "%0\(decCount)d", Int((frac * scale).rounded()))
        } else {
            decimal = ""
        }
    }

    // MARK: - Derived properties

    private var isSubArc: Bool {
        formatter.format == .mas || formatter.format == .µas
    }

    private var isHMS: Bool { formatter.format == .hms }

    private var primaryWidth: Int {
        switch formatter.format {
        case .hms:        return 2
        case .dms, .sdms: return formatter.requiresSign ? 2 : 3
        default:          return 2
        }
    }

    private var showSecondary: Bool { formatter.precision >= 2 }
    private var showTertiary:  Bool { formatter.precision >= 3 }
    private var decimalCount:  Int  { max(0, formatter.precision - 3) }
    private var showDecimal:   Bool { decimalCount > 0 }

    private var unit1: String {
        switch formatter.format {
        case .hms:        return "h"
        case .dms, .sdms: return "°"
        case .mas:        return "mas"
        case .µas:        return "µas"
        }
    }

    private var unit2: String { isHMS ? "m" : "′" }
    private var unit3: String { isHMS ? "s" : "″" }
}

// MARK: - Previews

#Preview("RA field (HMS p3)") {
    @Previewable @State var ra: Double = (6.0 + 45.0/60 + 8.9/3600) * 15 * .pi / 180
    AngleField($ra, formatter: .init(format: .hms, precision: 3))
        .padding()
}

#Preview("Dec field (SDMS p3)") {
    @Previewable @State var dec: Double = -(16.0 + 42.0/60 + 58.0/3600) * .pi / 180
    AngleField($dec, formatter: .init(format: .sdms, precision: 3))
        .padding()
}

#Preview("Galactic longitude (DMS p2, no sign)") {
    @Previewable @State var l: Double = 227.2 * .pi / 180
    AngleField($l, formatter: .init(format: .dms, precision: 2))
        .padding()
}

#Preview("Proper motion (mas p2)") {
    @Previewable @State var pm: Double = 1234.567 * .pi / (180.0 * 3_600_000.0)
    AngleField($pm, formatter: .init(format: .mas, precision: 4))
        .padding()
}
