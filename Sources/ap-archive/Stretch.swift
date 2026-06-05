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

    @Option(name: .long, help: "Normalization black bound in [0, 1] (the sub-range mapped to display 0).")
    var black: Double?

    @Option(name: .long, help: "Normalization white bound in [0, 1] (the sub-range mapped to display 1).")
    var white: Double?

    @Option(name: .long, help: "Black-point slider position in [0, 1] of the full data range.")
    var sliderBlack: Double?

    @Option(name: .long, help: "White-point slider position in [0, 1] of the full data range.")
    var sliderWhite: Double?

    @Flag(name: .long, help: "Clear all stretch and slider state, reverting to full-range identity.")
    var reset: Bool = false

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            printError("'\(id)' is not a valid UUID.")
            throw ExitCode.failure
        }

        let config = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        if reset {
            try await archive.updateStretchSettings(nil, sliderBlackNorm: nil, sliderWhiteNorm: nil, id: uuid)
            print("Cleared stretch and slider state for frame \(id) — reverted to identity.")
            return
        }

        guard black != nil || white != nil || sliderBlack != nil || sliderWhite != nil else {
            printError("Provide at least one of --black/--white (normalization) or --slider-black/--slider-white, or use --reset.")
            throw ExitCode.failure
        }

        var settings: StretchSettings? = nil
        if let b = black, let w = white {
            guard b >= 0.0, w <= 1.0 else { printError("--black and --white must be in [0, 1]."); throw ExitCode.failure }
            guard b < w               else { printError("--black must be less than --white."); throw ExitCode.failure }
            settings = StretchSettings(inputBlack: Float(b), inputWhite: Float(w))
        } else if black != nil || white != nil {
            printError("Provide both --black and --white together.")
            throw ExitCode.failure
        }

        let sbNorm = sliderBlack.map { Float($0) }
        let swNorm = sliderWhite.map { Float($0) }
        if let sb = sbNorm, let sw = swNorm, sb > sw {
            printError("--slider-black must be ≤ --slider-white.")
            throw ExitCode.failure
        }

        try await archive.updateStretchSettings(settings, sliderBlackNorm: sbNorm, sliderWhiteNorm: swNorm, id: uuid)

        var parts: [String] = []
        if let s = settings { parts.append(String(format: "norm=[%.4f, %.4f]", s.inputBlack, s.inputWhite)) }
        if let v = sbNorm   { parts.append(String(format: "slider_black=%.4f", v)) }
        if let v = swNorm   { parts.append(String(format: "slider_white=%.4f", v)) }
        print("Saved stretch for frame \(id):  \(parts.joined(separator: "  "))")
    }
}
