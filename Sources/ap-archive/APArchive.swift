import ArgumentParser
import AstrophotoArchiveKit
import AstrophotoKit
import Darwin
import Foundation

@main
struct APArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ap-archive",
        abstract: "Manage an astrophotography FITS archive.",
        discussion: "Archive location is set via the ASTROARCHIVE_PATH environment variable or --archive-path.",
        version: Version.string,
        subcommands: [Add.self, Find.self, Recent.self, Info.self, ListObjects.self, Stats.self, Remove.self, Reject.self, Copy.self, Frameset.self]
    )
}

// Shared option for all subcommands.
struct ArchivePathOption: ParsableArguments {
    @Option(name: .long, help: "Archive root directory (overrides ASTROARCHIVE_PATH).")
    var archivePath: String?

    func makeConfiguration() throws -> ArchiveConfiguration {
        if let path = archivePath {
            let expanded = (path as NSString).expandingTildeInPath
            return ArchiveConfiguration(rootURL: URL(fileURLWithPath: expanded))
        }
        return try ArchiveConfiguration.fromEnvironment()
    }
}

// Shared output helpers.
extension AsyncParsableCommand {
    func printError(_ message: String) {
        let stderr = FileHandle.standardError
        let line = "Error: \(message)\n"
        stderr.write(Data(line.utf8))
    }
}

/// Wraps `text` in ANSI orange escape codes when stdout is an interactive terminal.
func orangeText(_ text: String) -> String {
    isatty(STDOUT_FILENO) != 0
        ? "\u{001B}[38;5;208m\(text)\u{001B}[0m"
        : text
}

extension FileHandle: TextOutputStream {
    public func write(_ string: String) {
        write(Data(string.utf8))
    }
}
