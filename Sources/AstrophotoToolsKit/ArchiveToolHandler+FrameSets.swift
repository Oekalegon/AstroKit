import AstrophotoArchiveKit
import Foundation

extension ArchiveToolHandler {

    func archiveFrameSetInspect(_ args: [String: Any]) async throws -> String {
        let query           = makeFrameSetQuery(args)
        let maxFWHM         = args["max_fwhm"]         as? Double
        let maxEccentricity = args["max_eccentricity"] as? Double
        let inspection = try await archive.inspectFrameSet(
            query: query,
            maxFWHM: maxFWHM,
            maxEccentricity: maxEccentricity
        )
        return inspection.formatted(isDryRun: true)
    }

    func archiveFrameSetCreate(_ args: [String: Any]) async throws -> String {
        guard args["frame_type"] is String else {
            throw ToolError("frame_type is required for frameset creation (e.g. \"light\").")
        }
        let query           = makeFrameSetQuery(args)
        let force           = args["force"] as? Bool ?? false
        let maxFWHM         = args["max_fwhm"]         as? Double
        let maxEccentricity = args["max_eccentricity"] as? Double

        let objectName = args["object_name"] as? String
        let frameType  = args["frame_type"]  as? String
        let camera     = args["camera"]      as? String
        let filters    = args["filters"]     as? [String]
        let fromDate   = args["from_date"]   as? String
        let toDate     = args["to_date"]     as? String

        let setName: String
        if let n = args["name"] as? String {
            setName = n
        } else {
            var parts: [String] = []
            if let v = objectName       { parts.append(v) }
            if let v = frameType        { parts.append(v) }
            if let v = camera           { parts.append(v) }
            if let v = filters?.first   { parts.append(v) }
            if let f = fromDate, let t = toDate { parts.append("\(f)–\(t)") }
            setName = parts.isEmpty ? "frameset" : parts.joined(separator: " ")
        }

        let (fs, inspection) = try await archive.createFrameSet(
            name: setName,
            query: query,
            force: force,
            maxFWHM: maxFWHM,
            maxEccentricity: maxEccentricity
        )
        let iso = ISO8601DateFormatter()
        var lines = [
            "Created frame set '\(fs.name)'  [\(fs.id.uuidString)]",
            "",
        ]
        if fs.excludedFrameCount > 0 {
            lines.append("  \(fs.excludedFrameCount) frame(s) included but excluded by quality threshold.")
        }
        lines.append(inspection.formatted(isDryRun: false))
        lines.append("")
        lines.append("  Created: \(iso.string(from: fs.createdAt))")
        return lines.joined(separator: "\n")
    }

    func archiveFrameSetGet(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frameset_get requires a valid 'id' UUID.")
        }
        guard let fs = try await archive.frameSet(id: uuid) else {
            throw ToolError("No frame set with id \(idStr).")
        }
        let members = try await archive.members(inFrameSet: uuid)

        let iso = ISO8601DateFormatter()
        func row(_ label: String, _ value: String) -> String {
            String(format: "  %-14@ %@", (label + ":") as NSString, value as NSString)
        }

        var lines: [String] = []
        lines.append("Frame Set  \(fs.id.uuidString)")
        lines.append(String(repeating: "─", count: 60))
        lines.append(row("Name",   fs.name))
        lines.append(row("Type",   fs.frameType))
        lines.append(row("Level",  fs.processingLevel.rawValue))
        let framesSuffix = fs.excludedFrameCount > 0 ? " (\(fs.excludedFrameCount) excluded)" : ""
        lines.append(row("Frames", "\(fs.frameCount)\(framesSuffix)"))
        if let v = fs.objectName   { lines.append(row("Object",   v)) }
        if let v = fs.filter       {
            let label = v.contains(",") ? "Filters" : "Filter"
            lines.append(row(label, v))
        }
        if let v = fs.camera       { lines.append(row("Camera",   v)) }
        if let v = fs.exposureTime { lines.append(row("Exposure", String(format: "%.0f s", v))) }
        if let mn = fs.temperatureMin, let mx = fs.temperatureMax, let mean = fs.temperatureMean {
            if abs(mx - mn) < 0.5 {
                lines.append(row("Temperature", String(format: "%.1f °C", mean)))
            } else {
                lines.append(row("Temperature", String(format: "%.1f – %.1f °C (mean %.1f)", mn, mx, mean)))
            }
        }
        if let v = fs.gain         { lines.append(row("Gain",        String(format: "%.0f", v))) }
        if let v = fs.offset       { lines.append(row("Offset",      String(format: "%.0f", v))) }
        if let w = fs.width, let h = fs.height { lines.append(row("Size", "\(w) × \(h)")) }
        if let v = fs.pixelScale   { lines.append(row("Pixel scale", String(format: "%.3f \"/px", v))) }
        if let v = fs.focalLength  { lines.append(row("Focal length",String(format: "%.0f mm", v))) }
        if let v = fs.positionAngle { lines.append(row("Pos. angle", String(format: "%.1f°", v))) }
        if let from = fs.dateFrom, let to = fs.dateTo {
            let f = String(iso.string(from: from).prefix(10))
            let t = String(iso.string(from: to).prefix(10))
            lines.append(row("Date span", "\(f) – \(t)"))
        }
        lines.append(row("Created", iso.string(from: fs.createdAt)))

        let fsQuality = frameSetQualityParts(fs)
        if !fsQuality.isEmpty {
            lines.append("")
            lines.append("Quality (medians over active frames):")
            for part in fsQuality { lines.append("  \(part)") }
        }

        if !members.isEmpty {
            lines.append("")
            lines.append("Members:")
            for m in members {
                let f = m.frame
                var parts = ["id: \(f.id.uuidString)", "type: \(f.frameType)"]
                if m.excluded { parts.append("excluded: true") }
                if let r = m.excludedReason { parts.append("reason: \(r)") }
                if let v = f.objectName   { parts.append("object: \(v)") }
                if let v = f.filter       { parts.append("filter: \(v)") }
                if let v = f.exposureTime { parts.append(String(format: "exp: %.0fs", v)) }
                if let v = f.timestamp    { parts.append("date: \(String(iso.string(from: v).prefix(16)).replacingOccurrences(of: "T", with: " "))") }
                parts += frameIdentityParts(f)
                parts += frameQualityParts(f)
                parts.append("file: \(f.filePath)")
                lines.append("  { \(parts.joined(separator: ", ")) }")
            }
        }
        return lines.joined(separator: "\n")
    }

    func archiveFrameSetQuality(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frameset_quality requires a valid 'id' UUID.")
        }
        guard let fs = try await archive.frameSet(id: uuid) else {
            throw ToolError("No frame set with id \(idStr).")
        }
        let members = try await archive.members(inFrameSet: uuid)
        guard !members.isEmpty else { return "Frame set '\(fs.name)' has no frames." }

        let iso = ISO8601DateFormatter()
        let hasQuality = members.contains { $0.frame.starCount != nil || $0.frame.medianFWHM != nil }

        var lines: [String] = []
        let excludedSuffix = fs.excludedFrameCount > 0 ? ", \(fs.excludedFrameCount) excluded" : ""
        lines.append("Frame Set: \(fs.name)  [\(fs.id.uuidString)]")
        lines.append("Frames: \(members.count)\(excludedSuffix)")

        if !hasQuality {
            lines.append("")
            lines.append("No quality data available for this frameset.")
            lines.append("Run: ap-archive frameset quality \(fs.id.uuidString)")
            lines.append("  or: ap run frame_quality --input @frameset:\(fs.id.uuidString)")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        var table = TextTable(columns: [
            .init("ID"),
            .init("Object"),
            .init("Filter"),
            .init("Exposure", .right),
            .init("Stars", .right),
            .init("FWHM", .right),
            .init("Ecc", .right),
            .init("Background", .right),
            .init("Date"),
        ])
        for m in members {
            let f = m.frame
            let obj  = f.objectName ?? "-"
            let filt = f.filter ?? "-"
            let exp  = f.exposureTime.map { String(format: "%.0fs", $0) } ?? "-"
            let stars = f.starCount.map { "\($0)" } ?? "-"
            let fwhm: String
            if let px = f.medianFWHM {
                fwhm = f.medianFWHMArcsec.map { String(format: "%.2fpx/%.2f\"", px, $0) }
                    ?? String(format: "%.2fpx", px)
            } else { fwhm = "-" }
            let ecc = f.medianEccentricity.map { String(format: "%.3f", $0) } ?? "-"
            let bg: String
            if let e = f.backgroundNoiseElectrons {
                bg = String(format: "%.1fe⁻", e)
            } else if let n = f.backgroundNoise {
                bg = String(format: "%.1fADU", n)
            } else { bg = "-" }
            let date = f.timestamp.map {
                String(iso.string(from: $0).prefix(16)).replacingOccurrences(of: "T", with: " ")
            } ?? "-"
            let excludeFlag = m.excluded ? "* " : ""
            table.addRow([excludeFlag + f.id.uuidString, obj, filt, exp, stars, fwhm, ecc, bg, date])
        }
        lines.append(table.render())

        let active = members.filter { !$0.excluded }.map { $0.frame }
        let fwhmValues = active.compactMap { $0.medianFWHM }
        let eccValues  = active.compactMap { $0.medianEccentricity }
        if !fwhmValues.isEmpty || !eccValues.isEmpty {
            lines.append("Active frames (\(active.count)):")
            if !fwhmValues.isEmpty {
                let med = medianValue(fwhmValues)
                if let scale = active.compactMap({ $0.pixelScale }).first {
                    lines.append(String(format: "  Median FWHM:         %.2fpx / %.2f\"", med, med * scale))
                } else {
                    lines.append(String(format: "  Median FWHM:         %.2fpx", med))
                }
            }
            if !eccValues.isEmpty {
                lines.append(String(format: "  Median eccentricity: %.3f", medianValue(eccValues)))
            }
        }
        if fs.excludedFrameCount > 0 {
            lines.append("(* = excluded from frameset)")
        }
        return lines.joined(separator: "\n")
    }

    func archiveFrameSetAdd(_ args: [String: Any]) async throws -> String {
        let (setUUID, frameUUIDs) = try frameSetMemberArgs(args, tool: "archive_frameset_add")
        let force = args["force"] as? Bool ?? false
        let result = try await archive.addFrames(toFrameSet: setUUID, frameIDs: frameUUIDs, force: force)

        var lines = ["Added \(result.addedIDs.count) frame(s) to frame set '\(result.frameSet.name)'."]
        if !result.alreadyMemberIDs.isEmpty {
            lines.append("Skipped \(result.alreadyMemberIDs.count) frame(s) already in the set: "
                + result.alreadyMemberIDs.map { $0.uuidString }.joined(separator: ", "))
        }
        for (id, reason) in result.excludedReasons.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            lines.append("Frame \(id.uuidString) was added but marked excluded: \(reason)")
        }
        lines.append("The set now contains \(result.frameSet.frameCount) frame(s)"
            + (result.frameSet.excludedFrameCount > 0
                ? " (\(result.frameSet.excludedFrameCount) excluded)." : "."))
        return lines.joined(separator: "\n")
    }

    func archiveFrameSetRemove(_ args: [String: Any]) async throws -> String {
        let (setUUID, frameUUIDs) = try frameSetMemberArgs(args, tool: "archive_frameset_remove")
        let result = try await archive.removeFrames(fromFrameSet: setUUID, frameIDs: frameUUIDs)

        var lines = ["Removed \(result.removedIDs.count) frame(s) from frame set '\(result.frameSet.name)'."]
        if !result.notMemberIDs.isEmpty {
            lines.append("Skipped \(result.notMemberIDs.count) frame(s) not in the set: "
                + result.notMemberIDs.map { $0.uuidString }.joined(separator: ", "))
        }
        lines.append("The set now contains \(result.frameSet.frameCount) frame(s)"
            + (result.frameSet.excludedFrameCount > 0
                ? " (\(result.frameSet.excludedFrameCount) excluded)." : "."))
        return lines.joined(separator: "\n")
    }

    private func frameSetMemberArgs(_ args: [String: Any], tool: String) throws -> (UUID, [UUID]) {
        guard let setStr = args["frameset_id"] as? String, let setUUID = UUID(uuidString: setStr) else {
            throw ToolError("\(tool) requires a valid 'frameset_id' UUID.")
        }
        guard let idStrings = args["frame_ids"] as? [String], !idStrings.isEmpty else {
            throw ToolError("\(tool) requires a non-empty 'frame_ids' array.")
        }
        let frameUUIDs = try idStrings.map { s -> UUID in
            guard let uuid = UUID(uuidString: s) else {
                throw ToolError("\(tool): invalid frame UUID '\(s)'.")
            }
            return uuid
        }
        return (setUUID, frameUUIDs)
    }

    func archiveFrameSetExclude(_ args: [String: Any]) async throws -> String {
        guard let setStr = args["frameset_id"] as? String, let setUUID = UUID(uuidString: setStr) else {
            throw ToolError("archive_frameset_exclude requires a valid 'frameset_id' UUID.")
        }
        guard let frmStr = args["frame_id"] as? String, let frmUUID = UUID(uuidString: frmStr) else {
            throw ToolError("archive_frameset_exclude requires a valid 'frame_id' UUID.")
        }
        let undo   = args["undo"] as? Bool ?? false
        let reason = args["reason"] as? String
        try await archive.setMemberExcluded(
            frameSetID: setUUID, frameID: frmUUID,
            excluded: !undo, reason: undo ? nil : reason
        )
        if undo {
            return "Frame \(frmStr) re-included in frame set \(setStr)."
        } else {
            let suffix = reason.map { ": \($0)" } ?? ""
            return "Frame \(frmStr) marked as excluded in frame set \(setStr)\(suffix)."
        }
    }

    func archiveFrameSetDelete(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frameset_delete requires a valid 'id' UUID.")
        }
        try await archive.deleteFrameSet(id: uuid)
        return "Deleted frame set \(idStr)."
    }
}
