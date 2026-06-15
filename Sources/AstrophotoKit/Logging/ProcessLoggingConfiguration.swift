import Foundation

/// Global logging configuration for pipeline/process loggers.
///
/// This centralizes log level control so that different parts of the app
/// can adjust verbosity in one place.
public enum ProcessLogLevel: Int {
    case debug = 0
    case info
    case notice
    case warning
    case error
    case critical
}

public struct ProcessLoggingConfiguration {

    /// Singleton-style shared configuration.
    public static var shared = ProcessLoggingConfiguration()

    /// Global minimum log level for all `ProcessLogger` instances,
    /// unless they override it explicitly.
    public var minimumLevel: ProcessLogLevel = .info

    public init(minimumLevel: ProcessLogLevel = .info) {
        self.minimumLevel = minimumLevel
    }
}


