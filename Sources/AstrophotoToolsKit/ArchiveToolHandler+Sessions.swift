import AstrophotoArchiveKit
import Foundation

extension ArchiveToolHandler {

    func archiveSessions(_ args: [String: Any]) async throws -> String {
        let kindStr = args["kind"] as? String ?? "all"

        let sessions: [ObservingSession]
        if kindStr == "calibration" {
            sessions = try await archive.calibrationSessions()
        } else {
            let isNight: Bool? = kindStr == "night" ? true : kindStr == "day" ? false : nil
            if let n = args["latest_count"] as? Int {
                sessions = try await archive.latestSessions(limit: n, isNight: isNight)
            } else if let dateStr = args["date"] as? String {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd"
                guard let date = df.date(from: dateStr) else {
                    throw ToolError("Invalid date '\(dateStr)'. Use YYYY-MM-DD format.")
                }
                sessions = try await archive.sessions(on: date, isNight: isNight)
            } else if kindStr == "all" {
                sessions = try await archive.allSessions()
            } else {
                sessions = try await archive.sessions(isNight: isNight)
            }
        }
        if sessions.isEmpty { return "No sessions found." }
        return sessions.map { formatSession($0) }.joined(separator: "\n\n")
    }

    func archiveBackfillSessions() async throws -> String {
        try await archive.backfillSessions()
        try await archive.backfillCalibrationSessions()
        return "Session backfill complete."
    }

    func archiveSessionFrames(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["session_id"] as? String, let id = UUID(uuidString: idStr) else {
            throw ToolError("session_id must be a valid UUID string.")
        }
        guard let session = try await archive.session(id: id) else {
            throw ToolError("Session \(idStr) not found.")
        }
        let frames = try await archive.frames(inSession: id)
        let iso = ISO8601DateFormatter()
        var lines = ["\(session.name) (\(session.kindLabel)) — \(frames.count) raw frame(s):"]
        for f in frames {
            let ts  = f.timestamp.map { String(iso.string(from: $0).prefix(19)).replacingOccurrences(of: "T", with: " ") } ?? "-"
            let obj = f.objectName ?? "-"
            let flt = f.filter ?? "-"
            let exp = f.exposureTime.map { String(format: "%.1f s", $0) } ?? "-"
            lines.append("  [\(f.id.uuidString)]  \(ts)  \(obj)  \(flt)  \(exp)  \(f.filePath)")
        }
        return lines.joined(separator: "\n")
    }

    func archiveFrameSession(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["frame_id"] as? String, let id = UUID(uuidString: idStr) else {
            throw ToolError("frame_id must be a valid UUID string.")
        }
        guard let session = try await archive.session(forFrame: id) else {
            return "Frame \(idStr) has no session assigned (or is not a raw frame)."
        }
        return formatSession(session)
    }
}
