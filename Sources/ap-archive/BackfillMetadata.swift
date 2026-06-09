import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct BackfillMetadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill-metadata",
        abstract: "Re-read FITS headers to fill in missing observation metadata.",
        discussion: """
        Reads OBJECT, INSTRUME, TELESCOP, and OBSERVAT from the FITS file on disk for \
        each archived frame that is missing one or more of these fields, and updates the \
        archive database. Existing values are never overwritten.

        Also repairs missing observation timestamps: frames archived when DATE-OBS \
        carried a timezone designator (e.g. "Z") were previously stored without a \
        timestamp and filed under unknown-date/. This command reads DATE-OBS from the \
        FITS file and corrects the stored timestamp.

        By default only raw frames are processed. Pass --include-stacked to also process \
        stacked and calibrated frames.
        """
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Flag(name: .long, help: "Also process calibrated and stacked frames (not just raw).")
    var includeStacked: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON.")
    var json: Bool = false

    func run() async throws {
        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        // .stretched is omitted: no code path currently writes the STRETCHD FITS keyword,
        // so stretched frames cannot exist in archives produced by this toolchain.
        let levels: [ProcessingLevel] = includeStacked
            ? [.raw, .calibrated, .stacked]
            : [.raw]

        if !json { print("Backfilling observation metadata…") }

        let result = try await archive.backfillObservationMetadata(processingLevels: levels)

        if json {
            let obj: [String: Any] = [
                "updated":          result.updated,
                "already_complete": result.alreadyComplete,
                "failed":           result.failed
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("  Updated:          \(result.updated)")
            print("  Already complete: \(result.alreadyComplete)")
            if result.failed > 0 {
                print("  Failed (file unreadable): \(result.failed)")
            }
        }
    }
}
