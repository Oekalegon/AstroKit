import ArgumentParser
import AstrophotoArchiveKit
import AstrophotoKit
import Foundation

struct Stretch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save or clear the display stretch for an archived frame.",
        discussion: """
            Stores a normalized [0, 1] black/white point pair in the archive so the same
            stretch is applied every time the frame is opened. The underlying FITS file is
            never modified — only the archive database is updated.

            To normalize a stretch you have already set interactively in Navi, pass the
            current effective black and white point values as --black / --white.

            Use --reset to clear a previously saved stretch and revert to the full range.
            """
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Archive frame UUID.")
    var id: String

    @Option(name: .long, help: "Normalized [0, 1] black point (maps to display black).")
    var black: Double?

    @Option(name: .long, help: "Normalized [0, 1] white point (maps to display white).")
    var white: Double?

    @Flag(name: .long, help: "Clear a previously saved stretch and revert to identity (full range).")
    var reset: Bool = false

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            printError("'\(id)' is not a valid UUID.")
            throw ExitCode.failure
        }

        let config = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        if reset {
            try await archive.updateStretchSettings(nil, id: uuid)
            print("Cleared stretch for frame \(id) — reverted to identity (full range).")
            return
        }

        guard let black, let white else {
            printError("Provide --black and --white, or --reset to clear the stretch.")
            throw ExitCode.failure
        }
        guard black >= 0.0, white <= 1.0 else {
            printError("--black and --white must both be in [0, 1].")
            throw ExitCode.failure
        }
        guard black < white else {
            printError("--black (\(black)) must be less than --white (\(white)).")
            throw ExitCode.failure
        }

        let settings = StretchSettings(inputBlack: Float(black), inputWhite: Float(white))
        try await archive.updateStretchSettings(settings, id: uuid)
        print(String(format: "Saved stretch for frame %@:  black=%.4f  white=%.4f", id, black, white))
    }
}
