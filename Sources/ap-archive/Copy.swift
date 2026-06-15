import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Export a copy of a frame or frame set from the archive to a local path."
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Argument(help: "Frame or frame set UUID.")
    var id: String

    @Argument(help: "Destination: an existing directory, a new file path for a single frame, or a new directory path for a frame set.")
    var destination: String

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("Invalid UUID: \(id)")
        }

        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)

        let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)

        if let frame = try await archive.frame(id: uuid) {
            try copySingleFrame(frame, to: destURL)
        } else if let frameSet = try await archive.frameSet(id: uuid) {
            let members = try await archive.frames(inFrameSet: uuid)
            try copyFrameSet(frameSet, frames: members, to: destURL)
        } else {
            printError("No frame or frame set found with id \(id).")
            throw ExitCode.failure
        }
    }

    private func copySingleFrame(_ frame: ArchivedFrame, to dest: URL) throws {
        let fm  = FileManager.default
        let src = URL(fileURLWithPath: frame.filePath)

        let targetURL: URL
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            targetURL = dest.appendingPathComponent(src.lastPathComponent)
        } else {
            targetURL = dest
        }

        if fm.fileExists(atPath: targetURL.path) {
            printError("Destination already exists: \(targetURL.path)")
            throw ExitCode.failure
        }

        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: targetURL)
        print("Copied \(frame.id.uuidString)  →  \(targetURL.path)")
    }

    private func copyFrameSet(_ frameSet: ArchivedFrameSet, frames: [ArchivedFrame], to dest: URL) throws {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir), !isDir.boolValue {
            printError("Destination is an existing file. Frame sets must be copied to a directory.")
            throw ExitCode.failure
        }

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        var copied  = 0
        var skipped = 0
        for frame in frames {
            let src       = URL(fileURLWithPath: frame.filePath)
            let targetURL = dest.appendingPathComponent(src.lastPathComponent)

            if fm.fileExists(atPath: targetURL.path) {
                print("Skipped (already exists): \(src.lastPathComponent)")
                skipped += 1
                continue
            }

            try fm.copyItem(at: src, to: targetURL)
            copied += 1
        }

        print("Copied \(copied) frame(s) from '\(frameSet.name)' to \(dest.path).")
        if skipped > 0 {
            print("Skipped \(skipped) frame(s) — destination file(s) already exist.")
        }
    }
}
