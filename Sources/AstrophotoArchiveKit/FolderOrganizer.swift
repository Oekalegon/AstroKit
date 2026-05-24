import Foundation

enum FolderOrganizer {
    /// Returns the destination URL for a FITS file within the archive root.
    /// Structure: <root>/<object>/<YYYY-MM-DD>/<frame-type>/<filter>/<filename>
    static func destinationURL(
        for metadata: FrameArchiveMetadata,
        in archiveRoot: URL,
        filename: String
    ) -> URL {
        let object = metadata.objectName?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            ?? "unknown"

        let date: String
        if let ts = metadata.timestamp {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "UTC")
            date = df.string(from: ts)
        } else {
            date = "unknown-date"
        }

        let type   = metadata.frameType.isEmpty ? "unknown" : metadata.frameType
        let filter = metadata.filter?.trimmingCharacters(in: .whitespaces) ?? "no-filter"

        return archiveRoot
            .appendingPathComponent(object)
            .appendingPathComponent(date)
            .appendingPathComponent(type)
            .appendingPathComponent(filter)
            .appendingPathComponent(filename)
    }
}
