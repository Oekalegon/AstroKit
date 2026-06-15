import ArgumentParser
import AstrophotoArchiveKit
import Foundation

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List and manage observing sessions.",
        subcommands: [List.self, Backfill.self]
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

        @Option(name: .long, help: "Filter by session type: all (default), night, or day.")
        var kind: String = "all"

        @Flag(name: .shortAndLong, help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            guard kind == "all" || kind == "night" || kind == "day" else {
                printError("--kind must be 'all', 'night', or 'day'.")
                throw ExitCode.failure
            }
            let isNight: Bool? = kind == "night" ? true : kind == "day" ? false : nil

            let archive = try Archive(configuration: try archiveOptions.makeConfiguration())
            let sessions: [ObservingSession]

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
            } else {
                sessions = try await archive.sessions(isNight: isNight)
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
                    s.isNight ? "night" : "day",
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
                    "is_night":    s.isNight,
                    "latitude":    s.latitude,
                    "longitude":   s.longitude,
                    "frame_count": s.frameCount,
                    "added_at":    iso.string(from: s.addedAt),
                ]
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

    // MARK: - Backfill

    struct Backfill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "backfill",
            abstract: "Assign sessions to raw light frames that have site coordinates but no session yet.",
            discussion: "Reads SITELAT/SITELONG from the archive database and uses AstroKit to determine the correct night boundary. Safe to run multiple times."
        )

        @OptionGroup var archiveOptions: ArchivePathOption

        func run() async throws {
            let archive = try Archive(configuration: try archiveOptions.makeConfiguration())
            print("Backfilling observing sessions…")
            try await archive.backfillSessions()
            print("Done.")
        }
    }
}
