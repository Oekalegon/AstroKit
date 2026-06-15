import Foundation
import os

public struct ProcessLogger {

    private let pipeline: String
    private let processor: String?

    private let osLogger: Logger?

    /// Reuse the global process log level type.
    public typealias Level = ProcessLogLevel

    /// Minimum level that will actually be emitted.
    /// This is an app-controlled filter; OSLog may still filter further.
    public let minimumLevel: Level

    public init(
        pipeline: String,
        processor: String,
        osLogger: Logger? = nil,
        minimumLevel: Level = ProcessLoggingConfiguration.shared.minimumLevel
    ) {
        self.pipeline = pipeline
        self.processor = processor
        self.osLogger = osLogger
        self.minimumLevel = minimumLevel
    }

    private func shouldLog(_ level: Level) -> Bool {
        level.rawValue >= minimumLevel.rawValue
    }

    private func createLogMessage(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) -> String {
        let pipelineString = "[\(pipeline):\(runID.uuidString)]"
        let processString = processor != nil ? (process != nil ? "\(process!.uuidString):\(processor!)" : processor!) : nil
        let dataString = data != nil ? (stepLinkID != nil ? "\(data!.uuidString):\(stepLinkID!)" : data!.uuidString) : nil
        let messageArray = [pipelineString, processString, dataString].compactMap { $0 }
        return messageArray.joined(separator: " ") + " " + message
    }

    public func debug(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.debug), let osLogger else { return }
        osLogger.debug("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID), privacy: .public)")
    }

    public func notice(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.notice), let osLogger else { return }
        osLogger.notice("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID), privacy: .public)")
    }

    public func info(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.info), let osLogger else { return }
        osLogger.info("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID), privacy: .public)")
    }

    public func warning(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.warning), let osLogger else { return }
        osLogger.warning("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID), privacy: .public)")
    }

    public func error(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.error), let osLogger else { return }
        osLogger.error("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID), privacy: .public)")
    }

    public func critical(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.critical), let osLogger else { return }
        osLogger.critical("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID), privacy: .public)")
    }

    public func log(
        _ message: String,
        runID: UUID,
        process: UUID? = nil,
        data: UUID? = nil,
        stepLinkID: String? = nil
    ) {
        guard shouldLog(.info), let osLogger else { return }
        osLogger.info("\(createLogMessage(message, runID: runID, process: process, data: data, stepLinkID: stepLinkID)  , privacy: .public)")
    }
}