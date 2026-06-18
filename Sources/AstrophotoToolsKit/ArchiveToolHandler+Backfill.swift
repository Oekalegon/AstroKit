import AstrophotoArchiveKit
import AstrophotoKit
import Foundation

extension ArchiveToolHandler {

    func archiveBackfillMetadata(_ args: [String: Any]) async throws -> String {
        let includeStacked = args["include_stacked"] as? Bool ?? false
        // .stretched is omitted: no code path currently writes the STRETCHD FITS keyword,
        // so stretched frames cannot exist in archives produced by this toolchain.
        let levels: [ProcessingLevel] = includeStacked
            ? [.raw, .calibrated, .stacked]
            : [.raw]
        let result = try await archive.backfillObservationMetadata(processingLevels: levels)
        var lines = [
            "Backfilled observation metadata:",
            "  Updated:          \(result.updated)",
            "  Skipped:          \(result.skipped)",
        ]
        if result.frameSetsUpdated > 0 {
            lines.append("  Framesets (pixel scale): \(result.frameSetsUpdated)")
        }
        if result.failed > 0 {
            lines.append("  Failed (unreadable): \(result.failed)")
            lines += result.failedPaths.map { "    \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    func archiveSetPixelScale(_ args: [String: Any]) async throws -> String {
        let telescope = args["telescope"] as? String
        let camera    = args["camera"]    as? String
        let overwrite = args["overwrite"] as? Bool ?? false

        let scale: Double
        if let explicit = args["arcsec_per_pixel"] as? Double {
            scale = explicit
        } else if let fl = args["focal_length_mm"] as? Double,
                  let px = args["pixel_size_um"] as? Double {
            let binning = (args["binning"] as? Int) ?? 1
            guard let computed = PixelScale.arcsecPerPixel(
                pixelSizeMicrons: px, binning: binning, focalLengthMm: fl
            ) else {
                throw ToolError("focal_length_mm, pixel_size_um, and binning must all be positive.")
            }
            scale = computed
        } else {
            throw ToolError("archive_set_pixel_scale requires 'arcsec_per_pixel', or 'focal_length_mm' + 'pixel_size_um'.")
        }

        let (frames, frameSets) = try await archive.setPixelScale(
            scale, telescope: telescope, camera: camera, overwrite: overwrite
        )
        let scope = [telescope.map { "telescope: \($0)" }, camera.map { "camera: \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        return String(
            format: "Set pixel scale %.4f\"/px (%@):\n  Frames updated:    %d\n  Framesets updated: %d",
            scale, scope, frames, frameSets
        )
    }

    func archiveFrameLineage(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String, let uuid = UUID(uuidString: idStr) else {
            throw ToolError("archive_frame_lineage requires a valid 'id' UUID.")
        }
        guard let frame = try await archive.frame(id: uuid) else {
            throw ToolError("No frame with id \(idStr) found.")
        }
        let lineage = try await archive.fullLineage(containing: frame)

        if lineage.count == 1 {
            return "Frame \(idStr) has no recorded predecessors or successors — it is the only version."
        }

        let currentV = lineage.currentVersionNumber
        let iso = ISO8601DateFormatter()
        var lines: [String] = ["Lineage chain (\(lineage.count) versions, newest → oldest) — current: v\(currentV)"]

        for (index, version) in lineage.chain.enumerated() {
            let versionNumber = lineage.count - index
            let isCurrent = index == lineage.currentIndex
            var frameLine = "v\(versionNumber)  \(version.id.uuidString)"
            if isCurrent { frameLine += "  ← current" }
            frameLine += "  added: \(String(iso.string(from: version.addedAt).prefix(19)))"
            if let fwhm = version.medianFWHM {
                frameLine += String(format: "  fwhm: %.2fpx", fwhm)
                if let arcsec = version.medianFWHMArcsec { frameLine += String(format: " (%.2f\")", arcsec) }
            }
            if let stars = version.starCount { frameLine += "  stars: \(stars)" }
            lines.append(frameLine)

            if !isCurrent {
                let diff = try await archive.diff(lineage.current, predecessor: version)
                lines.append(diff.formatted(otherVersion: versionNumber, currentVersion: currentV))
            }
        }

        return lines.joined(separator: "\n")
    }
}
