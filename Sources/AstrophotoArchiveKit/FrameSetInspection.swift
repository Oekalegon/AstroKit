import Foundation

/// A read-only report produced by inspecting which frames would form a frame set,
/// given a query. Used both for dry-run previews and as part of the result returned
/// after a frame set is actually created.
public struct FrameSetInspection: Sendable {

    /// One row in a property distribution: a formatted label and the number of frames
    /// that carry that value.
    public struct Entry: Sendable {
        public var label: String
        public var count: Int
    }

    public var matchedFrameCount: Int

    // Value distributions (entries sorted by count descending).
    public var frameTypes: [Entry]
    public var filters: [Entry]          // "(none)" when a frame has no filter
    public var processingLevels: [Entry]
    public var objectNames: [Entry]      // "(unknown)" when object is absent
    public var cameras: [Entry]          // "(unknown)" when camera is absent
    public var pixelScales: [Entry]      // formatted as "1.240 \"/px"
    public var focalLengths: [Entry]     // formatted as "800 mm"
    public var positionAngles: [Entry]   // formatted as "0.0°"

    // Date span across all member frames.
    public var dateFrom: Date?
    public var dateTo: Date?

    // Temperature statistics across all member frames that carry a temperature.
    public var temperatureMin: Double?
    public var temperatureMax: Double?
    public var temperatureMean: Double?

    // Validation results.
    /// `false` when creation is impossible regardless of `--force`
    /// (no frames matched, or mixed types, or mixed processing levels).
    public var canCreate: Bool
    /// `true` when the only blocker is mixed filters, which `--force` bypasses.
    public var needsForce: Bool
    /// Human-readable issue descriptions.
    public var issues: [String]

    /// All matched frames, including those that would be excluded by quality thresholds.
    public var frames: [ArchivedFrame]
    /// Subset of `frames` that would be marked as excluded due to `maxFWHM` or `maxEccentricity`
    /// thresholds. These frames ARE included in the created frame set but skipped during processing.
    public var excludedFrames: [ArchivedFrame]

    /// Number of active (non-excluded) frames.
    public var activeFrameCount: Int { frames.count - excludedFrames.count }
}

// MARK: - Formatting helpers used by both CLI and MCP

extension FrameSetInspection {

    /// Multi-line text summary suitable for terminal or MCP output.
    public func formatted(isDryRun: Bool) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []

        if isDryRun {
            let excludedNote = excludedFrames.isEmpty ? "" : ", \(excludedFrames.count) excluded by quality threshold"
            lines.append("Dry-run inspection — \(matchedFrameCount) frame(s) matched\(excludedNote)")
        } else {
            let excludedNote = excludedFrames.isEmpty ? "" : " (\(excludedFrames.count) excluded by quality threshold)"
            lines.append("Frame set properties\(excludedNote):")
        }
        lines.append(String(repeating: "─", count: 52))

        func section(_ title: String, _ entries: [Entry]) {
            guard !entries.isEmpty else { return }
            let uniform = entries.count == 1
            let summary = entries.map { "\($0.label) (\($0.count))" }.joined(separator: ", ")
            let mark = uniform ? "✓" : "≠"
            lines.append(String(format: "  %-14@ %@ %@", (title + ":") as NSString, mark, summary))
        }

        section("Frame type",  frameTypes)
        section("Filter",      filters)
        section("Processing",  processingLevels)
        section("Object",      objectNames)
        section("Camera",      cameras)
        section("Pixel scale", pixelScales)
        section("Focal length",focalLengths)
        section("Pos. angle",  positionAngles)

        // Date span
        if let from = dateFrom, let to = dateTo {
            let fromStr = String(iso.string(from: from).prefix(10))
            let toStr   = String(iso.string(from: to).prefix(10))
            let days    = Int(to.timeIntervalSince(from) / 86400)
            lines.append(String(format: "  %-14@ %@", "Date span:", "\(fromStr) – \(toStr) (\(days) day(s))"))
        } else if let from = dateFrom {
            lines.append(String(format: "  %-14@ %@", "Date:", String(iso.string(from: from).prefix(10))))
        }

        // Temperature
        if let mn = temperatureMin, let mx = temperatureMax, let mean = temperatureMean {
            if abs(mx - mn) < 0.5 {
                lines.append(String(format: "  %-14@ %.1f °C", "Temperature:", mean))
            } else {
                lines.append(String(format: "  %-14@ %.1f – %.1f °C (mean %.1f)", "Temperature:", mn, mx, mean))
            }
        }

        // Issues / status
        if !issues.isEmpty {
            lines.append("")
            for issue in issues { lines.append("  ⚠ \(issue)") }
        }

        lines.append("")
        if !canCreate {
            lines.append("  ✗ Cannot create — resolve the issues above.")
        } else if needsForce {
            lines.append("  ⚠ Needs --force to create (mixed filters).")
        } else if isDryRun {
            lines.append("  ✓ Ready to create.")
        }

        // Per-frame table
        if !frames.isEmpty {
            lines.append("")
            lines.append("Frames (\(frames.count)):")
            var table = TextTable(columns: [
                .init("UUID"),
                .init("Object"),
                .init("Filter"),
                .init("Exposure", .right),
                .init("Date"),
            ])
            for f in frames {
                let obj  = f.objectName ?? "-"
                let filt = f.filter ?? "-"
                let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
                let date = f.timestamp.map { String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "-"
                table.addRow([f.id.uuidString, obj, filt, exp, date])
            }
            lines.append(contentsOf: table.renderLines(indent: "  "))
        }

        return lines.joined(separator: "\n")
    }
}
