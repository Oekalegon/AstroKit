import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct BackfillMetadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill-metadata",
        abstract: "Re-read FITS headers to fill in missing observation and acquisition metadata.",
        discussion: """
        Reads the following FITS keywords for each archived frame that is missing one or \
        more of them, and updates the archive database. Existing values are never overwritten.

        Observation strings: OBJECT, INSTRUME, TELESCOP, OBSERVAT
        Numeric acquisition data: EXPTIME, GAIN, OFFSET, CCD-TEMP, EGAIN, FOCALLEN, PIXSCALE, POSANGLE

        Calibration frames (bias, dark, flat) never carry a target object; OBJECT, RA, \
        and DEC are not backfilled for them.

        When EXPTIME is recovered, the frame's deduplication signature is recomputed so \
        that re-importing the same file later does not create a duplicate entry.

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
                "updated":      result.updated,
                "skipped":      result.skipped,
                "failed":       result.failed,
                "failed_paths": result.failedPaths,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
            print(String(data: data, encoding: .utf8)!)
        } else {
            print("  Updated:          \(result.updated)")
            print("  Skipped:          \(result.skipped)")
            if result.failed > 0 {
                print("  Failed (file unreadable): \(result.failed)")
                for path in result.failedPaths { print("    \(path)") }
            }
        }
    }
}
