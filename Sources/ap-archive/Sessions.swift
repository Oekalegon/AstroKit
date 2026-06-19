import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List and manage observing sessions.",
        subcommands: [List.self, Frames.self, Backfill.self]
    )

    // MARK: - List

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List observing sessions, newest first.",
            discussion: "Without options lists all sessions. Use --date to filter by night, --latest to get the N most recent, and --kind to restrict to night or day sessions."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Option(name: .long, help: "Show sessions for this night (YYYY-MM-DD, local date of the preceding sunset).")
        var date: String?

        @Option(name: .long, help: "Return only the N most recent sessions.")
        var latest: Int?

        @Option(name: .long, help: "Filter by session type: all (default), night, day, or calibration.")
        var kind: String = "all"

        @Flag(name: .shortAndLong, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            guard ["all", "night", "day", "calibration"].contains(kind) else {
                printError("--kind must be 'all', 'night', 'day', or 'calibration'.")
                throw ExitCode.failure
            }

            let archive = try Archive(configuration: try archiveOptions.makeConfiguration())
            let sessions: [ObservingSession]

            if kind == "calibration" {
                sessions = try await archive.calibrationSessions()
            } else {
                let isNight: Bool? = kind == "night" ? true : kind == "day" ? false : nil
                if let n = latest {
                    sessions = try await archive.latestSessions(limit: n, isNight: isNight)
                } else if let dateStr = date {
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.dateFormat = "yyyy-MM-dd"
                    guard let parsed = df.date(from: dateStr) else {
                        printError("Invalid date '\(dateStr)'. Use YYYY-MM-DD.")
                        throw ExitCode.failure
                    }
                    sessions = try await archive.sessions(on: parsed, isNight: isNight)
                } else if kind == "all" {
                    sessions = try await archive.allSessions()
                } else {
                    sessions = try await archive.sessions(isNight: isNight)
                }
            }

            if json {
                printJSON(sessions)
            } else {
                printTable(sessions)
            }
        }

        private func printTable(_ sessions: [ObservingSession]) {
            if sessions.isEmpty {
                print("No sessions found.")
                return
            }
            let iso = ISO8601DateFormatter()
            func shortTime(_ date: Date) -> String {
                String(iso.string(from: date).prefix(16)).replacingOccurrences(of: "T", with: " ")
            }
            print("Observing sessions (\(sessions.count)):\n")
            var table = TextTable(columns: [
                .init("Session"),
                .init("Kind"),
                .init("Frames", .right),
                .init("Start (UTC)"),
                .init("End (UTC)"),
                .init("ID"),
            ])
            for s in sessions {
                table.addRow([
                    s.name,
                    s.kindLabel,
                    "\(s.frameCount)",
                    s.startTime.map { shortTime($0) } ?? "-",
                    s.endTime.map   { shortTime($0) } ?? "-",
                    s.id.uuidString,
                ])
            }
            print(table.render())
        }

        private func printJSON(_ sessions: [ObservingSession]) {
            let iso = ISO8601DateFormatter()
            let dicts: [[String: Any]] = sessions.map { s in
                var d: [String: Any] = [
                    "id":          s.id.uuidString,
                    "name":        s.name,
                    "frame_count": s.frameCount,
                    "added_at":    iso.string(from: s.addedAt),
                ]
                d["frame_type"] = s.frameType
                if !s.isCalibration {
                    d["is_night"]  = s.isNight
                    d["latitude"]  = s.latitude
                    d["longitude"] = s.longitude
                }
                if let t = s.startTime { d["start_time"] = iso.string(from: t) }
                if let t = s.endTime   { d["end_time"]   = iso.string(from: t) }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
    }

    // MARK: - Frames

    struct Frames: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "frames",
            abstract: "List the raw light frames in an observing session.",
            discussion: "Prints each frame's timestamp, object, filter, exposure, and file path."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        @Argument(help: "Session UUID.")
        var sessionID: String

        @Flag(name: .shortAndLong, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            guard let id = UUID(uuidString: sessionID) else {
                printError("Invalid session UUID '\(sessionID)'.")
                throw ExitCode.failure
            }
            let archive = try Archive(configuration: try archiveOptions.makeConfiguration())
            guard let session = try await archive.session(id: id) else {
                printError("Session \(sessionID) not found.")
                throw ExitCode.failure
            }
            let frames = try await archive.frames(inSession: id)

            if json {
                printJSON(session: session, frames: frames)
            } else {
                printTable(session: session, frames: frames)
            }
        }

        private func printTable(session: ObservingSession, frames: [ArchivedFrame]) {
            let iso = ISO8601DateFormatter()
            func shortTime(_ date: Date) -> String {
                String(iso.string(from: date).prefix(16)).replacingOccurrences(of: "T", with: " ")
            }
            let kind = session.kindLabel
            print("\(session.name) (\(kind)) — \(frames.count) frame(s)\n")
            var table = TextTable(columns: [
                .init("Timestamp (UTC)"),
                .init("Object"),
                .init("Filter"),
                .init("Exp (s)", .right),
                .init("File"),
            ])
            for f in frames {
                table.addRow([
                    f.timestamp.map { shortTime($0) } ?? "-",
                    f.objectName ?? "-",
                    f.filter ?? "-",
                    f.exposureTime.map { String(format: "%.1f", $0) } ?? "-",
                    f.filePath,
                ])
            }
            print(table.render())
        }

        private func printJSON(session: ObservingSession, frames: [ArchivedFrame]) {
            let iso = ISO8601DateFormatter()
            let frameDicts: [[String: Any]] = frames.map { f in
                var d: [String: Any] = ["id": f.id.uuidString, "file_path": f.filePath]
                if let t  = f.timestamp    { d["timestamp"]    = iso.string(from: t) }
                if let v  = f.objectName   { d["object"]       = v }
                if let v  = f.filter       { d["filter"]       = v }
                if let v  = f.exposureTime { d["exposure_s"]   = v }
                return d
            }
            var root: [String: Any] = [
                "session_id": session.id.uuidString,
                "session_name": session.name,
                "frames": frameDicts,
            ]
            root["frame_type"] = session.frameType
            if !session.isCalibration {
                root["is_night"] = session.isNight
            }
            if let data = try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) { print(str) }
        }
    }

    // MARK: - Backfill

    struct Backfill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "backfill",
            abstract: "Assign sessions to unassigned raw light and calibration frames.",
            discussion: "Groups light frames by night/location and calibration frames by consecutive sequences. Safe to run multiple times."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        func run() async throws {
            let archive = try Archive(configuration: try archiveOptions.makeConfiguration())
            print("Backfilling observing sessions…")
            try await archive.backfillSessions()
            print("Backfilling calibration sessions…")
            try await archive.backfillCalibrationSessions()
            print("Done.")
        }
    }
}
