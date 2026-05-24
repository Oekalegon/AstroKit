import Foundation

public struct ArchiveStatistics: Sendable {
    public var objectCount: Int
    public var frameCount: Int
    public var frameCountByType: [String: Int]
    public var frameCountByTypeAndFilter: [String: [String: Int]]
    public var processedFramesByObject: [String: Int]
    public var usedBytes: Int64
    public var availableBytes: Int64

    public var usedBytesFormatted: String { formatBytes(usedBytes) }
    public var availableBytesFormatted: String { formatBytes(availableBytes) }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
