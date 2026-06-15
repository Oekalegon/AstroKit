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
        diff.formatted(otherVersion: otherVersion, currentVersion: currentVersion)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .forEach { print("     \($0)") }
    }
}
