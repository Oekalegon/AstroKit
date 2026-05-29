import Foundation

/// A simple dynamic-width text table renderer for terminal output.
///
/// Column widths are computed from the actual data, so no hardcoded widths are needed.
/// The last column is never padded (it grows freely).
public struct TextTable {

    public enum Alignment { case left, right }

    public struct Column {
        public let header: String
        public let alignment: Alignment
        public init(_ header: String, _ alignment: Alignment = .left) {
            self.header = header
            self.alignment = alignment
        }
    }

    public let columns: [Column]
    private var rows: [[String]] = []

    public init(columns: [Column]) {
        self.columns = columns
    }

    public mutating func addRow(_ cells: [String]) {
        rows.append(cells)
    }

    /// Returns header line, separator line, then one line per data row.
    /// Useful when per-row coloring is needed — apply color before printing each data line.
    public func renderLines(indent: String = "") -> [String] {
        guard !columns.isEmpty else { return [] }
        let widths = computeWidths()
        var lines: [String] = []
        lines.append(indent + format(cells: columns.map(\.header), widths: widths))
        lines.append(indent + widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        for row in rows {
            lines.append(indent + format(cells: row, widths: widths))
        }
        return lines
    }

    public func render(indent: String = "") -> String {
        renderLines(indent: indent).joined(separator: "\n")
    }

    private func computeWidths() -> [Int] {
        var widths = columns.map { $0.header.count }
        for row in rows {
            for (i, cell) in row.prefix(widths.count).enumerated() {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return widths
    }

    private func format(cells: [String], widths: [Int]) -> String {
        (0..<widths.count).map { i in
            let cell = i < cells.count ? cells[i] : ""
            guard i < widths.count - 1 else { return cell }
            let alignment = columns[i].alignment
            return pad(cell, to: widths[i], alignment: alignment)
        }.joined(separator: "  ")
    }

    private func pad(_ s: String, to width: Int, alignment: Alignment) -> String {
        guard s.count < width else { return s }
        let padding = String(repeating: " ", count: width - s.count)
        return alignment == .left ? s + padding : padding + s
    }
}
