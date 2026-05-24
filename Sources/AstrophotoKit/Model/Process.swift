import Foundation

/// Represents a process, i.e. a specific run of a processor.
public struct Process {

    /// The unique identifier for this process.
    public let identifier: UUID = UUID()

    /// The identifier of the step from the YAML configuration.
    /// This matches the `id` field in the pipeline step definition.
    public let stepIdentifier: String

    /// The identifier of the processor that produced this process.
    public let processorIdentifier: String

    /// The input data names for this process.
    public let inputData: [ProcessDataLink]

    /// The parameters for this process.
    /// 
    /// The parameters are a dictionary of parameter names and values.
    public let parameters: [String: Parameter]

    /// The output data names for this process.
    public var outputData: [ProcessDataLink]

    /// The current status of this process.
    public var currentStatus: ProcessStatus {
        return statusHistory.first!
    }

    /// The history of the statuses of this process.
    /// 
    /// The history of the statuses is an array of statuses, 
    /// where the first status is the current status.
    /// The last status is the oldest status.
    public var statusHistory: [ProcessStatus] = []

    /// The date and time the process was created.
    public var createdAt: Date {
        for status in statusHistory {
            if case .pending(let date) = status {
                return date
            }
        }
        fatalError("Process must have a pending status in its history")
    }

    /// The date and time the process was started.
    public var startedAt: Date? {
        for status in statusHistory {
            if case .running(let date, _) = status {
                return date
            }
        }
        return nil
    }

    /// The date and time the process was finished.
    public var finishedAt: Date? {
        for status in statusHistory {
            if case .completed(let date) = status {
                return date
            } else if case .failed(let date, _) = status {
                return date
            } else if case .cancelled(let date) = status {
                return date
            }
        }
        return nil
    }

    /// The duration of the process execution.
    /// 
    /// Returns the time difference between when the process started running
    /// and when it finished (completed, failed, or cancelled).
    /// Returns `nil` if the process hasn't started or hasn't finished yet.
    public var duration: TimeInterval? {
        guard let startTime = startedAt, let endTime = finishedAt else {
            return nil
        }
        return endTime.timeIntervalSince(startTime)
    }

    public init(
        stepIdentifier: String,
        processorIdentifier: String,
        inputData: [(String, DataType, CollectionMode, String)] = [], // (name, type, collectionMode, stepLinkID)
        parameters: [String: Parameter] = [:],
        outputData: [(String, DataType)] = [] // (name, type) - stepLinkID will be constructed as stepIdentifier.name
    ) {
        self.stepIdentifier = stepIdentifier
        self.processorIdentifier = processorIdentifier
        let processId = self.identifier
        self.inputData = inputData.map { .input(process: processId, link: $0.0, type: $0.1, collectionMode: $0.2, stepLinkID: $0.3) }
        self.parameters = parameters
        self.outputData = outputData.map { 
            let stepLinkID = "\(stepIdentifier).\($0.0)"
            return .output(process: processId, link: $0.0, type: $0.1, stepLinkID: stepLinkID)
        }
        self.statusHistory.append(.pending(date: Date()))
    }

    /// Create a Process from a PipelineStep.
    ///
    /// This initializer creates a Process instance from a PipelineStep configuration.
    /// The process will be initialized with pending status and will have input/output
    /// data names extracted from the step configuration.
    /// - Parameter step: The pipeline step to create the process from
    public init(step: PipelineStep) {
        self.stepIdentifier = step.id
        self.processorIdentifier = step.type
        let processId = self.identifier
        // Extract input data names from the step's data inputs and create ProcessDataLinks
        self.inputData = step.dataInputs.map { dataInput in
            let collectionMode = dataInput.collectionMode ?? .individually
            // stepLinkID comes from the `from` field in the YAML
            // If `from` doesn't contain a dot, it's a pipeline input, so convert to "initial.input_name"
            let stepLinkID: String
            if dataInput.from.contains(".") {
                // It's a step output reference (e.g., "grayscale.grayscale_frame")
                stepLinkID = dataInput.from
            } else {
                // It's a pipeline input reference (e.g., "input_frame" -> "initial.input_frame")
                stepLinkID = "initial.\(dataInput.from)"
            }
            return .input(process: processId, link: dataInput.name, type: dataInput.type, collectionMode: collectionMode, stepLinkID: stepLinkID)
        }
        // Parameters are left empty as they need to be resolved from pipeline parameters
        // ParameterSpec values need to be resolved to actual Parameter values during execution
        self.parameters = [:] // TODO: Resolve parameters from step parameters
        // Extract output data names from the step's outputs and create ProcessDataLinks
        self.outputData = step.outputs.map { output in
            // stepLinkID is stepIdentifier.outputName (e.g., "grayscale.grayscale_frame")
            let stepLinkID = "\(step.id).\(output.name)"
            return .output(process: processId, link: output.name, type: output.type, stepLinkID: stepLinkID)
        }
        self.statusHistory.append(.pending(date: Date()))
    }

    /// Add an output data name to this process.
    /// 
    /// The output data name is the name of the data that this process produces.
    /// - Parameters:
    ///   - name: The name of the output data.
    ///   - type: The type of the output data.
    public mutating func addOutputData(name: String, type: DataType) {
        let stepLinkID = "\(self.stepIdentifier).\(name)"
        self.outputData.append(.output(process: self.identifier, link: name, type: type, stepLinkID: stepLinkID))
    }

    /// Set the status of this process.
    /// 
    /// This method adds the new status to the beginning of the status history,
    /// making it the current status.
    /// - Parameter status: The new status to set
    public mutating func setStatus(_ status: ProcessStatus) {
        statusHistory.insert(status, at: 0)
    }

    /// Mark this process as running.
    /// 
    /// This method sets the process status to running with the current date and initial progress.
    /// - Parameter progress: Optional progress value (default: 0.0)
    /// - Parameter message: Optional progress message (default: "Starting execution")
    public mutating func markAsRunning(progress: Double = 0.0, message: String = "Starting execution") {
        let progressObj = Progress(value: progress, date: Date(), message: message)
        setStatus(.running(date: Date(), progress: progressObj))
    }

    /// Mark this process as completed.
    /// 
    /// This method sets the process status to completed with the current date.
    public mutating func markAsCompleted() {
        setStatus(.completed(date: Date()))
    }

    /// Mark this process as failed.
    /// 
    /// This method sets the process status to failed with the current date and error.
    /// - Parameter error: The error that caused the process to fail
    public mutating func markAsFailed(error: Error) {
        setStatus(.failed(date: Date(), error: error))
    }

    /// Mark this process as cancelled.
    /// 
    /// This method sets the process status to cancelled with the current date.
    public mutating func markAsCancelled() {
        setStatus(.cancelled(date: Date()))
    }

    /// Mark this process as paused.
    /// 
    /// This method sets the process status to paused with the current date.
    public mutating func markAsPaused() {
        setStatus(.paused(date: Date()))
    }

    /// Mark this process as resumed.
    /// 
    /// This method sets the process status to resumed with the current date.
    public mutating func markAsResumed() {
        setStatus(.resumed(date: Date()))
    }
}

/// The status of a process.
public enum ProcessStatus {

    /// The process is pending.
    /// 
    /// The date and time the process was set to pending.
    case pending(date: Date)

    /// The process is running.
    /// 
    /// The date and time the process was set to running.
    case running(date: Date, progress: Progress)

    /// The process is paused.
    /// 
    /// The date and time the process was set to paused.
    case paused(date: Date)

    /// The process is resumed.
    /// 
    /// The date and time the process was set to resumed.
    case resumed(date: Date)

    /// The process is completed.
    /// 
    /// The date and time the process was set to completed.
    case completed(date: Date)

    /// The process is cancelled.
    /// 
    /// The date and time the process was set to cancelled.
    case cancelled(date: Date)

    /// The process failed.
    /// 
    /// The date and time the process was set to failed.
    /// The error that caused the process to fail.
    case failed(date: Date, error: Error)
}

/// The progress of a process.
public struct Progress {

    /// The progress value.
    /// 
    /// The progress value is a value between 0.0 and 1.0.
    var value: Double

    /// The date and time the progress was set.
    /// 
    /// The date and time the progress was set.
    var date: Date

    /// The progress message.
    /// 
    /// The progress message is a message describing the progress.
    var message: String
}
