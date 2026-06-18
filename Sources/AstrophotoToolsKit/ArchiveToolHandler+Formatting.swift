import AstrophotoArchiveKit
import Foundation

extension ArchiveToolHandler {

    /// Core identification fields for a single frame (level, rejection state).
    func frameIdentityParts(_ f: ArchivedFrame) -> [String] {
        var parts: [String] = []
        parts.append("level: \(f.processingLevel.rawValue)")
        if f.rejected { parts.append("rejected: true") }
        return parts
    }

    /// Quality fields for a single frame, ready to append to a parts array.
    func frameQualityParts(_ f: ArchivedFrame) -> [String] {
        var parts: [String] = []
        if let v = f.starCount          { parts.append("stars: \(v)") }
        if let px = f.medianFWHM {
            if let arcsec = f.medianFWHMArcsec {
                parts.append(String(format: "fwhm: %.2fpx/%.2f\"", px, arcsec))
            } else {
                parts.append(String(format: "fwhm: %.2fpx", px))
            }
        }
        if let v = f.medianEccentricity { parts.append(String(format: "ecc: %.3f", v)) }
        if let e = f.backgroundNoiseElectrons {
            parts.append(String(format: "bg: %.1fe⁻", e))
        } else if let n = f.backgroundNoise {
            parts.append(String(format: "bg: %.1fADU", n))
        }
        if let v = f.saturatedStarCount, v > 0 { parts.append("sat_stars: \(v)") }
        if let v = f.hotPixelCount,      v > 0 { parts.append("hot_px: \(v)") }
        return parts
    }

    /// Quality aggregate fields for a frameset (medians over active members).
    func frameSetQualityParts(_ fs: ArchivedFrameSet) -> [String] {
        var parts: [String] = []
        if let v = fs.medianStarCount { parts.append(String(format: "med_stars: %.0f", v)) }
        if let px = fs.medianFWHM {
            if let arcsec = fs.medianFWHMArcsec {
                parts.append(String(format: "med_fwhm: %.2fpx/%.2f\"", px, arcsec))
            } else {
                parts.append(String(format: "med_fwhm: %.2fpx", px))
            }
        }
        if let v = fs.medianEccentricity { parts.append(String(format: "med_ecc: %.3f", v)) }
        if let e = fs.medianBackgroundNoiseElectrons {
            parts.append(String(format: "med_bg: %.1fe⁻", e))
        } else if let n = fs.medianBackgroundNoise {
            parts.append(String(format: "med_bg: %.1fADU", n))
        }
        return parts
    }

    func formatRecentActivity(_ entries: [RecentEntry]) -> String {
        let iso = ISO8601DateFormatter()
        func shortDate(_ date: Date) -> String {
            String(iso.string(from: date).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }

        var lines = ["Recent archive activity (\(entries.count)):"]
        for entry in entries {
            switch entry {
            case .session(let s, let recency):
                lines.append("  { kind: session, id: \(s.id.uuidString), name: \(s.name), type: \(s.isNight ? "night" : "day"), frames: \(s.frameCount), recency: \(shortDate(recency)) }")
            case .dateGroup(let label, let utcDate, let recency, let count):
                lines.append("  { kind: date_group, name: \(label), utc_date: \(utcDate), frames: \(count), recency: \(shortDate(recency)) }")
            case .frame(let f):
                var parts = [
                    "kind: frame",
                    "id: \(f.id.uuidString)",
                    "level: \(f.processingLevel.rawValue)",
                    "type: \(f.frameType)",
                    "added: \(shortDate(f.addedAt))",
                ]
                if let v = f.objectName   { parts.append("object: \(v)") }
                if let v = f.filter       { parts.append("filter: \(v)") }
                if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
                parts += frameIdentityParts(f)
                parts += frameQualityParts(f)
                parts.append("file: \((f.filePath as NSString).lastPathComponent)")
                lines.append("  { \(parts.joined(separator: ", ")) }")
            case .frameSet(let fs):
                var parts = [
                    "kind: frameset",
                    "id: \(fs.id.uuidString)",
                    "name: \(fs.name)",
                    "level: \(fs.processingLevel.rawValue)",
                    "type: \(fs.frameType)",
                    "frames: \(fs.frameCount)",
                    "created: \(shortDate(fs.createdAt))",
                ]
                if let v = fs.objectName { parts.append("object: \(v)") }
                if let v = fs.filter     { parts.append("filter: \(v)") }
                lines.append("  { \(parts.joined(separator: ", ")) }")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatSession(_ s: ObservingSession) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["\(s.name)  [\(s.isNight ? "night" : "day")]  \(s.frameCount) frame(s)"]
        lines.append("  id:       \(s.id.uuidString)")
        lines.append(String(format: "  location: %.4f°, %.4f°", s.latitude, s.longitude))
        if let t = s.startTime { lines.append("  start:    \(String(iso.string(from: t).prefix(16)).replacingOccurrences(of: "T", with: " "))") }
        if let t = s.endTime   { lines.append("  end:      \(String(iso.string(from: t).prefix(16)).replacingOccurrences(of: "T", with: " "))") }
        return lines.joined(separator: "\n")
    }
}
