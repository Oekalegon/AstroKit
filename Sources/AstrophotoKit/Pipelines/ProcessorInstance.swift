import Foundation

/// Log severity levels for processor instance logging
public enum LogSeverity: String, Codable {
    case debug
    case info
    case warning
    case error
    case fatal
}

/// A log entry for a processor instance
public struct LogEntry: Codable {
    /// Timestamp when the log entry was created
    public let timestamp: Date

    /// Severity level of the log entry
    public let severity: LogSeverity

    /// The log message
    public let message: String

    /// Optional additional context or metadata
    public let context: [String: String]?

    public init(
        severity: LogSeverity,
        message: String,
        context: [String: String]? = nil
    ) {
        self.timestamp = Date()
        self.severity = severity
        self.message = message
        self.context = context
    }
}

/// Status of a processor instance during execution
public enum ProcessorInstanceStatus {
    /// Waiting for required inputs to become available
    case pending
    /// Currently executing
    case running
    /// Successfully completed
    case completed
    /// Execution failed with an error
    case failed(Error)

    /// Check if two statuses are equal (ignoring error details for failed cases)
    public static func == (lhs: ProcessorInstanceStatus, rhs: ProcessorInstanceStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.running, .running), (.completed, .completed):
            return true
        case (.failed, .failed):
            // Consider failed states equal regardless of error details
            return true
        default:
            return false
        }
    }
}

extension ProcessorInstanceStatus: Equatable {}

/// Wrapper around a pipeline step that tracks execution state for a specific instance
/// Each instance has a unique ID and tracks its own status and progress
/// Implemented as an actor for thread-safe access in concurrent execution contexts
public actor ProcessorInstance {
    /// Unique identifier for this processor instance
    public nonisolated let instanceId: String

    /// The step configuration this instance is executing
    public nonisolated let step: PipelineStep

    /// Identifiers for the inputs being processed (e.g., image identifiers, table identifiers)
    /// A processor instance can process multiple inputs (e.g., two frames, or a frame and a table)
    public nonisolated let inputIdentifiers: [String]

    /// Current status of this instance
    private(set) var status: ProcessorInstanceStatus

    /// Progress of execution (0.0 to 1.0)
    private(set) var progress: Double

    /// Log entries for this processor instance
    private(set) var logEntries: [LogEntry] = []

    public init(
        instanceId: String,
        step: PipelineStep,
        inputIdentifiers: [String] = []
    ) {
        self.instanceId = instanceId
        self.step = step
        self.inputIdentifiers = inputIdentifiers
        self.status = .pending
        self.progress = 0.0
    }

    /// Get the current status
    public func getStatus() -> ProcessorInstanceStatus {
        return status
    }

    /// Get the current progress
    public func getProgress() -> Double {
        return progress
    }

    /// Optional error if execution failed
    public func getError() -> Error? {
        if case .failed(let err) = status {
            return err
        }
        return nil
    }

    /// Update the status of this instance
    public func updateStatus(_ newStatus: ProcessorInstanceStatus) {
        status = newStatus
    }

    /// Update the progress of this instance
    /// - Parameter progress: Progress value between 0.0 and 1.0
    public func updateProgress(_ progress: Double) {
        self.progress = max(0.0, min(1.0, progress))
    }

    /// Add a log entry to this instance
    /// - Parameters:
    ///   - severity: The severity level of the log entry
    ///   - message: The log message
    ///   - context: Optional additional context or metadata
    public func log(severity: LogSeverity, message: String, context: [String: String]? = nil) {
        let entry = LogEntry(severity: severity, message: message, context: context)
        logEntries.append(entry)
    }

    /// Convenience method to log a debug message
    public func logDebug(_ message: String, context: [String: String]? = nil) {
        log(severity: .debug, message: message, context: context)
    }

    /// Convenience method to log an info message
    public func logInfo(_ message: String, context: [String: String]? = nil) {
        log(severity: .info, message: message, context: context)
    }

    /// Convenience method to log a warning message
    public func logWarning(_ message: String, context: [String: String]? = nil) {
        log(severity: .warning, message: message, context: context)
    }

    /// Convenience method to log an error message
    public func logError(_ message: String, context: [String: String]? = nil) {
        log(severity: .error, message: message, context: context)
    }

    /// Convenience method to log a fatal message
    public func logFatal(_ message: String, context: [String: String]? = nil) {
        log(severity: .fatal, message: message, context: context)
    }

    /// Get log entries filtered by severity level
    /// - Parameter severity: The severity level to filter by
    /// - Returns: Array of log entries with the specified severity
    public func getLogEntries(severity: LogSeverity) -> [LogEntry] {
        return logEntries.filter { $0.severity == severity }
    }

    /// Get all log entries
    /// - Returns: Array of all log entries
    public func getAllLogEntries() -> [LogEntry] {
        return logEntries
    }

    /// Check if this instance can run based on available data
    /// This method is nonisolated because it only reads immutable properties (step)
    /// and checks status, which is safe to read concurrently
    public nonisolated func canRun(availableData: [String: Any], currentStatus: ProcessorInstanceStatus) -> Bool {
        guard currentStatus == .pending else { return false }

        for dataInput in step.dataInputs {
            let fromParts = dataInput.from.split(separator: ".", maxSplits: 1)
            let sourceData: Any?

            if fromParts.count == 2 {
                // Step output: "step_id.output_name" or "instance_id.output_name"
                let sourceId = String(fromParts[0])
                let outputName = String(fromParts[1])
                // Try instance-specific key first: "sourceInstanceId.outputName"
                let instanceKey = "\(sourceId).\(outputName)"
                sourceData = availableData[instanceKey] ?? availableData[outputName]
            } else {
                // Pipeline input: "input_name"
                let inputName = String(fromParts[0])
                sourceData = availableData[inputName]
            }

            if sourceData == nil {
                return false
            }
        }
        return true
    }
}
