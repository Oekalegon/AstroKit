import os

/// Logger extension for AstrophotoKit operations
extension Logger {
    /// Logger for FITSIO-related operations
    public static let swiftfitsio = Logger(subsystem: "com.astrophotokit", category: "swift-fitsio")

    /// Logger for pipeline-related operations
    public static let pipeline = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-pipeline")

    /// Logger for processor-related operations
    /// All processors should use this logger instead of creating their own
    public static let processor = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-processor")

    /// Logger for filter-related operations
    public static let filter = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-filter")

    /// Logger for computer-related operations
    public static let computers = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-computers")

    /// Logger for data-related operations
    public static let data = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-data")

    /// Logger for UI-related operations
    public static let ui = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-ui")
}

