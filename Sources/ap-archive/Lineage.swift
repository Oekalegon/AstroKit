import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Lineage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the version history for a pipeline result frame."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Frame UUID (from ap-archive find or ap-archive recent).")
    var id: String

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("'\(id)' is not a valid UUID.")
        }
        let archive = try Archive(configuration: archiveOptions.makeConfiguration())
        guard let frame = try await archive.frame(id: uuid) else {
            throw ValidationError("No frame with id \(id) found in the archive.")
        }

        let lineage = try await archive.fullLineage(containing: frame)

        if lineage.count == 1 {
            print("No lineage — this frame has no recorded predecessors or successors.")
            print()
            printFrameLine(lineage.chain[0], version: 1, isCurrent: true)
            return
        }

        let currentV = lineage.currentVersionNumber
        print("Lineage chain (\(lineage.count) versions, newest → oldest) — current: v\(currentV)")
        print(String(repeating: "─", count: 60))

        let current = lineage.current

        for (index, version) in lineage.chain.enumerated() {
            let versionNumber = lineage.count - index
            let isCurrent = index == lineage.currentIndex
            printFrameLine(version, version: versionNumber, isCurrent: isCurrent)

            if !isCurrent {
                // diff(current, predecessor: version) → from = version, to = current.
                // Arrow direction "vN → vCurrent" consistently shows what the version had
                // and what current has, regardless of whether the version is older or newer.
                let diff = try await archive.diff(current, predecessor: version)
                printDiff(diff, otherVersion: versionNumber, currentVersion: currentV)
            }
            print()
        }
    }

    // MARK: - Formatting

    private func printFrameLine(_ f: ArchivedFrame, version: Int, isCurrent: Bool) {
        let tag = isCurrent ? " ← current" : ""
        let iso = ISO8601DateFormatter()
        print("  v\(version)  \(f.id.uuidString)\(tag)")
        print("       Added: \(iso.string(from: f.addedAt))")
        if let fwhm = f.medianFWHM {
            let arcsec = f.medianFWHMArcsec.map { String(format: " (%.2f\")", $0) } ?? ""
            let stars  = f.starCount.map { "  stars: \($0)" } ?? ""
            print(String(format: "       FWHM:  %.2f px\(arcsec)\(stars)", fwhm))
        }
    }

    private func printDiff(_ diff: FrameDiff, otherVersion: Int, currentVersion: Int) {
        var lines: [String] = []

        if !diff.parameterChanges.isEmpty {
            lines.append("     Parameters (v\(otherVersion) → v\(currentVersion)):")
            for change in diff.parameterChanges.sorted(by: { $0.key < $1.key }) {
                let from = change.from.map(\.description) ?? "(absent)"
                let to   = change.to.map(\.description)   ?? "(removed)"
                lines.append("       \(change.key): \(from) → \(to)")
            }
        }

        if !diff.inputsAdded.isEmpty {
            lines.append("     Inputs added vs v\(otherVersion): \(diff.inputsAdded.count)")
        }
        if !diff.inputsRemoved.isEmpty {
            lines.append("     Inputs removed vs v\(otherVersion): \(diff.inputsRemoved.count)")
        }

        let q = diff.quality
        var qualityLines: [String] = []
        if let old = q.fwhm.from, let new = q.fwhm.to {
            qualityLines.append(String(format: "FWHM %.2f→%.2f px", old, new))
        }
        if let old = q.starCount.from, let new = q.starCount.to {
            qualityLines.append("stars \(old)→\(new)")
        }
        if let old = q.eccentricity.from, let new = q.eccentricity.to {
            qualityLines.append(String(format: "ecc %.3f→%.3f", old, new))
        }
        if let old = q.backgroundNoiseElectrons.from, let new = q.backgroundNoiseElectrons.to {
            qualityLines.append(String(format: "bg %.1f→%.1f e⁻", old, new))
        }
        if !qualityLines.isEmpty {
            lines.append("     Quality (v\(otherVersion) → v\(currentVersion)): " + qualityLines.joined(separator: "  "))
        }

        if lines.isEmpty {
            lines.append("     (identical to v\(currentVersion))")
        }

        lines.forEach { print($0) }
    }
}
