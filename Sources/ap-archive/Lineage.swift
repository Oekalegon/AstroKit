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

        let chain = try await archive.lineage(of: frame)
        if chain.count == 1 {
            print("No lineage — this frame has no recorded predecessors.")
            print()
            printFrameLine(chain[0], version: 1, total: 1, isNewest: true)
            return
        }

        print("Lineage chain (\(chain.count) versions, newest → oldest)")
        print(String(repeating: "─", count: 60))

        for (index, current) in chain.enumerated() {
            let versionNumber = chain.count - index
            printFrameLine(current, version: versionNumber, total: chain.count, isNewest: index == 0)

            // Print diff between this version and the next (older) one.
            if index + 1 < chain.count {
                let predecessor = chain[index + 1]
                let diff = try await archive.diff(current, predecessor: predecessor)
                printDiff(diff)
                print()
            }
        }
    }

    // MARK: - Formatting

    private func printFrameLine(_ f: ArchivedFrame, version: Int, total: Int, isNewest: Bool) {
        let tag = isNewest ? " ← current" : ""
        let iso = ISO8601DateFormatter()
        print("  v\(version)  \(f.id.uuidString)\(tag)")
        print("       Added: \(iso.string(from: f.addedAt))")
        if let fwhm = f.medianFWHM {
            let arcsec = f.medianFWHMArcsec.map { String(format: " (%.2f\")", $0) } ?? ""
            let stars  = f.starCount.map { "  stars: \($0)" } ?? ""
            print(String(format: "       FWHM:  %.2f px\(arcsec)\(stars)", fwhm))
        }
    }

    private func printDiff(_ diff: FrameDiff) {
        var lines: [String] = []

        if !diff.parameterChanges.isEmpty {
            lines.append("     Parameters changed:")
            for change in diff.parameterChanges.sorted(by: { $0.key < $1.key }) {
                let from = change.from ?? "(absent)"
                let to   = change.to   ?? "(removed)"
                lines.append("       \(change.key): \(from) → \(to)")
            }
        }

        if !diff.inputsAdded.isEmpty {
            lines.append("     Inputs added:   \(diff.inputsAdded.count)")
        }
        if !diff.inputsRemoved.isEmpty {
            lines.append("     Inputs removed: \(diff.inputsRemoved.count)")
        }

        let q = diff.quality
        var qualityLines: [String] = []
        if let old = q.fwhm.from, let new = q.fwhm.to {
            qualityLines.append(String(format: "FWHM %.2f → %.2f px", old, new))
        }
        if let old = q.starCount.from, let new = q.starCount.to {
            qualityLines.append("stars \(old) → \(new)")
        }
        if let old = q.eccentricity.from, let new = q.eccentricity.to {
            qualityLines.append(String(format: "ecc %.3f → %.3f", old, new))
        }
        if let old = q.backgroundNoiseElectrons.from, let new = q.backgroundNoiseElectrons.to {
            qualityLines.append(String(format: "bg %.1f → %.1f e⁻", old, new))
        }
        if !qualityLines.isEmpty {
            lines.append("     Quality:  " + qualityLines.joined(separator: "  "))
        }

        if lines.isEmpty {
            lines.append("     (no parameter or quality changes recorded)")
        }

        print("  ↑")
        lines.forEach { print($0) }
        print("  ↓")
    }
}
