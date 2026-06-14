import Foundation

public extension FrameDiff {
    /// Returns a human-readable description of what changed between the other version
    /// (v`otherVersion`) and the current version (v`currentVersion`).
    ///
    /// The returned string has no leading indentation — callers prefix lines as needed
    /// for their output context (CLI, MCP, etc.).
    func formatted(otherVersion: Int, currentVersion: Int) -> String {
        var lines: [String] = []

        if !parameterChanges.isEmpty {
            lines.append("Parameters (v\(otherVersion) → v\(currentVersion)):")
            for change in parameterChanges.sorted(by: { $0.key < $1.key }) {
                let from = change.from.map(\.description) ?? "(absent)"
                let to   = change.to.map(\.description)   ?? "(removed)"
                lines.append("  \(change.key): \(from) → \(to)")
            }
        }

        if !inputsAdded.isEmpty   { lines.append("Inputs added vs v\(otherVersion): \(inputsAdded.count)") }
        if !inputsRemoved.isEmpty { lines.append("Inputs removed vs v\(otherVersion): \(inputsRemoved.count)") }

        let q = quality
        var qualParts: [String] = []
        if let old = q.fwhm.from,                    let new = q.fwhm.to                    { qualParts.append(String(format: "FWHM %.2f→%.2f px", old, new)) }
        if let old = q.starCount.from,                let new = q.starCount.to                { qualParts.append("stars \(old)→\(new)") }
        if let old = q.eccentricity.from,             let new = q.eccentricity.to             { qualParts.append(String(format: "ecc %.3f→%.3f", old, new)) }
        if let old = q.backgroundNoiseElectrons.from, let new = q.backgroundNoiseElectrons.to { qualParts.append(String(format: "bg %.1f→%.1f e⁻", old, new)) }
        if !qualParts.isEmpty {
            lines.append("Quality (v\(otherVersion) → v\(currentVersion)): " + qualParts.joined(separator: "  "))
        }

        return lines.isEmpty ? "(identical to v\(currentVersion))" : lines.joined(separator: "\n")
    }
}
