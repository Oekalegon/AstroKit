import Foundation
import Metal
import os

/// The runner for a pipeline.
/// 
/// The runner is responsible for executing the pipeline.
/// It is responsible for tracking the data that is available for the pipeline
/// and the processes that are currently running in the pipeline.
public actor PipelineRunner {

    /// The pipeline to execute.
    /// 
    /// The pipeline is the pipeline to execute.
    private let pipeline: Pipeline

    /// The data stack for the pipeline.
    /// 
    /// The data stack is used to track the data that is available for the pipeline.
    public let dataStack: DataStack

    /// The process stack for the pipeline.
    public let processStack: ProcessStack

    /// Initialize the pipeline runner with a pipeline.
    /// - Parameter pipeline: The pipeline to execute.
    public init(pipeline: Pipeline) {
        self.pipeline = pipeline
        self.dataStack = DataStack()
        self.processStack = ProcessStack()
    }

    /// Execute this pipeline asynchronously with parallel execution when dependencies allow
    /// Uses a data-driven execution model: tracks available data and checks pending step instances
    /// when new data becomes available. Each step execution gets a unique instance ID.
    /// - Parameters:
    ///   - inputs: Dictionary of pipeline input name to input data
    ///   - parameters: Dictionary of parameter name to parameter value
    ///   - device: Metal device for GPU operations
    ///   - commandQueue: Metal command queue for GPU operations
    ///   - registry: Processor registry to look up processors (defaults to shared registry)
    /// - Returns: Dictionary of output name to output data (from all step outputs)
    /// - Throws: ProcessorExecutionError or PipelineConfigurationError if execution fails
    public func execute(
        inputs: [String: Any],
        parameters: [String: Parameter] = [:],
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        registry: ProcessorRegistry = .shared
    ) async throws -> [ProcessData] {

        // This represents the initial process
        let initialProcess = Process(
            stepIdentifier: "initial",
            processorIdentifier: "initial"
        )

        // Create the initial input data for the pipeline.
        try await self.createInitialInputData(
            from: inputs,
            device: device,
            initialProcess: initialProcess,
            dataStack: dataStack
        )

        // Preconfigure all pipeline processes
        try await self.preconfigureProcesses(pipelineParameters: parameters)

        // Run the pipeline.
        try await self.runPipeline(device: device, commandQueue: commandQueue, registry: registry)

        // Get all the output data from the data stack.
        let outputData = await dataStack.getAll()
        return outputData
    }

    private func runPipeline(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        registry: ProcessorRegistry
    ) async throws {
        var iterationCount = 0
        let maxIterations = 100 // Safety limit to prevent infinite loops
        var executedProcessIDs: Set<UUID> = [] // Track executed processes to avoid re-execution

        while true {
            iterationCount += 1
            if iterationCount > maxIterations {
                Logger.pipeline.error(
                    "Pipeline execution exceeded maximum iterations (\(maxIterations)). Possible infinite loop."
                )
                throw ProcessorExecutionError.executionFailed(
                    "Pipeline execution exceeded maximum iterations. Possible circular dependency or infinite loop."
                )
            }

            // Get all pending processes that have all their inputs ready (excluding already executed ones)
            let readyProcesses = await processStack.getReadyPending(
                dataStack: dataStack,
                excludeProcesses: executedProcessIDs
            )

            Logger.pipeline.debug("Iteration \(iterationCount): Found \(readyProcesses.count) ready processes")
            
            if readyProcesses.isEmpty {
                // Log why we're stopping
                let pendingCount = await processStack.getPending().count
                let totalCount = await processStack.count()
                Logger.pipeline.debug("No ready processes. Pending: \(pendingCount), Total: \(totalCount), Executed: \(executedProcessIDs.count)")
                break
            }

            // Filter processes to only those with available processors
            let (processesToExecute, processesWithoutProcessors) = await filterProcessesWithProcessors(
                readyProcesses: readyProcesses,
                registry: registry
            )

            // Check if we can continue or if we're done
            if processesToExecute.isEmpty {
                let shouldContinue = await checkCompletionWhenNoProcessors(
                    readyProcesses: readyProcesses,
                    processesWithoutProcessors: processesWithoutProcessors,
                    executedProcessIDs: executedProcessIDs
                )
                if !shouldContinue {
                    break
                }
            }

            // Execute all ready processes
            // First, check if any processes need to be split (collection inputs with individually mode)
            var processesToRun: [Process] = []
            for process in processesToExecute {
                if let splitProcesses = await splitProcessForCollectionInputs(process: process) {
                    // Process was split - add the split processes instead
                    for splitProcess in splitProcesses {
                        await processStack.add(process: splitProcess)
                        await setupProcessInputLinks(process: splitProcess)
                        // Create output data for each split process
                        try await createProcessOutputData(process: splitProcess)
                        processesToRun.append(splitProcess)
                    }
                    // Mark original process as cancelled since we split it
                    var cancelledProcess = process
                    cancelledProcess.markAsCancelled()
                    await processStack.update(process: cancelledProcess)
                } else {
                    // Process doesn't need splitting, execute as normal
                    processesToRun.append(process)
                }
            }

            // Execute all processes (original or split)
            for process in processesToRun {
                try await executeProcess(
                    process: process,
                    device: device,
                    commandQueue: commandQueue,
                    registry: registry
                )
                executedProcessIDs.insert(process.identifier)
            }

            // Check if we should complete after this iteration
            let processesExecutedThisIteration = processesToExecute.count
            if processesExecutedThisIteration == 0 {
                let shouldContinue = await checkIterationCompletion(
                    processesWithoutProcessors: processesWithoutProcessors,
                    executedProcessIDs: executedProcessIDs
                )
                if !shouldContinue {
                    break
                }
            }

            Logger.pipeline.debug(
                "Iteration \(iterationCount) complete. Executed \(processesExecutedThisIteration) process(es). Total executed: \(executedProcessIDs.count)"
            )
        }

        Logger.pipeline.info("Pipeline execution complete after \(iterationCount) iterations")
    }

    /// Filters ready processes into those with available processors and those without
    /// - Parameters:
    ///   - readyProcesses: Processes that are ready to execute
    ///   - registry: Processor registry to look up processors
    /// - Returns: Tuple of (processes with processors, processes without processors)
    private func filterProcessesWithProcessors(
        readyProcesses: [Process],
        registry: ProcessorRegistry
    ) async -> ([Process], [Process]) {
        var processesToExecute: [Process] = []
        var processesWithoutProcessors: [Process] = []

        for process in readyProcesses {
            let processorID = process.processorIdentifier
            let processor = await registry.get(id: processorID)
            if processor != nil {
                processesToExecute.append(process)
            } else {
                processesWithoutProcessors.append(process)
                Logger.pipeline.warning(
                    "Process '\(process.stepIdentifier)' (type: '\(processorID)') is ready but processor not available - will remain pending"
                )
            }
        }

        return (processesToExecute, processesWithoutProcessors)
    }

    /// Checks if pipeline should complete when no processes can execute
    /// - Parameters:
    ///   - readyProcesses: Processes that were ready but may not have processors
    ///   - processesWithoutProcessors: Processes that don't have processors available
    ///   - executedProcessIDs: Set of already executed process IDs
    /// - Returns: True if pipeline should continue, false if it should complete
    private func checkCompletionWhenNoProcessors(
        readyProcesses: [Process],
        processesWithoutProcessors: [Process],
        executedProcessIDs: Set<UUID>
    ) async -> Bool {
        let remainingReady = readyProcesses.count
        if remainingReady > 0 {
            Logger.pipeline.warning(
                "\(remainingReady) process(es) are ready but have no processors available. Pipeline cannot continue."
            )

            let totalProcesses = await processStack.count()
            let executedCount = executedProcessIDs.count
            let pendingCount = await processStack.getPending().count
            Logger.pipeline.debug(
                "Status: \(executedCount) executed, \(pendingCount) pending, \(totalProcesses) total"
            )

            // If all processes are either executed or missing processors, we're done
            if executedCount + processesWithoutProcessors.count >= totalProcesses {
                Logger.pipeline.info("All executable processes completed. Remaining processes have no processors.")
                return false
            }
        }
        // No more work can be done
        return false
    }

    /// Splits a process into multiple processes if it has collection inputs with individually mode
    /// This is an implicit "split" process that expands a FrameSet into individual Frames
    /// - Parameter process: The process to potentially split
    /// - Returns: Array of split processes if splitting occurred, nil if no splitting needed
    private func splitProcessForCollectionInputs(process: Process) async -> [Process]? {
        // Find the first collection input with individually mode
        for inputLink in process.inputData {
            if case .input(_, let linkName, let type, let collectionMode, let stepLinkID) = inputLink {
                if type == .frameSet && collectionMode == .individually {
                    // Look up the FrameSet in the data stack
                    if let frameSet = await dataStack.get(by: inputLink) as? FrameSet {
                        let frames = frameSet.frames
                        if frames.count > 1 {
                            // We need to split - create one process per frame
                            var splitProcesses: [Process] = []
                            
                            for (index, frame) in frames.enumerated() {
                                // Create individual Frame data items for each frame in the FrameSet
                                // Each frame needs to be added to the data stack with an outputLink
                                // that matches the stepLinkID the split process will look for
                                var individualFrame = frame
                                // Set the outputLink to match what the split process will look for
                                // The stepLinkID should match the input link's stepLinkID
                                individualFrame.outputLink = .output(
                                    process: UUID(), // Synthetic process ID for the split
                                    link: linkName,
                                    type: .frame,
                                    stepLinkID: stepLinkID // Use the stepLinkID from the input link
                                )
                                // Add the individual frame to the data stack
                                await dataStack.add(data: individualFrame)

                                // Create a new process for this frame
                                // Modify the input link to be a frame instead of frameSet
                                let modifiedInputData = process.inputData.map { inputLink in
                                    if case .input(let processId, let inputLinkName, _, let inputCollectionMode, let inputStepLinkID) = inputLink {
                                        if inputLinkName == linkName {
                                            // Change this input to be a frame (not frameSet) for the split process
                                            // Use the same stepLinkID so it matches the individual frame we just created
                                            return ProcessDataLink.input(
                                                process: processId,
                                                link: inputLinkName,
                                                type: .frame,
                                                collectionMode: inputCollectionMode,
                                                stepLinkID: inputStepLinkID
                                            )
                                        }
                                    }
                                    return inputLink
                                }

                                // Create unique step identifier for each split process
                                let splitStepIdentifier = "\(process.stepIdentifier)[\(index)]"

                                // IMPORTANT: Keep the same stepLinkID for all outputs from split processes
                                // This allows them to be collected later by the merge process
                                let modifiedOutputData = process.outputData.map { outputLink -> ProcessDataLink in
                                    if case .output(let processId, let outputLinkName, let outputType, let originalOutputStepLinkID) = outputLink {
                                        // Keep the original stepLinkID so all split outputs share the same stepLinkID
                                        // This is the key for the merge process to find them all
                                        return .output(
                                            process: processId,
                                            link: outputLinkName,
                                            type: outputType,
                                            stepLinkID: originalOutputStepLinkID
                                        )
                                    }
                                    return outputLink
                                }

                                // Create the split process with modified input/output data
                                // Convert ProcessDataLinks back to tuples for Process.init
                                // Convert ProcessDataLinks to tuples for Process.init
                                // Note: Using a typealias to avoid large tuple warning
                                typealias InputDataTuple = (String, DataType, CollectionMode, String)
                                let inputDataTuples = modifiedInputData.compactMap { link -> InputDataTuple? in
                                    if case .input(_, let linkName, let type, let collectionMode, let stepLinkID) = link {
                                        return (linkName, type, collectionMode, stepLinkID)
                                    }
                                    return nil
                                }
                                let outputDataTuples = modifiedOutputData.compactMap { link -> (String, DataType)? in
                                    if case .output(_, let linkName, let type, _) = link {
                                        return (linkName, type)
                                    }
                                    return nil
                                }

                                let splitProcess = Process(
                                    stepIdentifier: splitStepIdentifier,
                                    processorIdentifier: process.processorIdentifier,
                                    inputData: inputDataTuples,
                                    parameters: process.parameters,
                                    outputData: outputDataTuples
                                )
                                
                                // Note: Process.init will create stepLinkIDs like "step[0].outputName"
                                // The merge logic will match on the base stepLinkID (without the index)

                                splitProcesses.append(splitProcess)
                            }
                            
                            Logger.pipeline.info("Split process '\(process.stepIdentifier)' into \(splitProcesses.count) processes for collection input '\(linkName)'")
                            return splitProcesses
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Synthesizes a FrameSet from individual frames that share the same base stepLinkID
    /// This is an implicit "merge" process that collects individual Frames into a FrameSet
    /// - Parameters:
    ///   - stepLinkID: The stepLinkID to match frames by (e.g., "subtract_bias_from_dark.calibrated_dark")
    ///   - linkName: The link name for the synthesized FrameSet
    /// - Returns: A FrameSet containing all matching frames, or nil if no frames found
    private func synthesizeFrameSetFromFrames(stepLinkID: String, linkName: String) async -> FrameSet? {
        // Find all frames in the data stack that have a matching base stepLinkID
        // Split processes create outputs with stepLinkIDs like "step[0].output", "step[1].output"
        // We need to match on the base part (e.g., "step.output") to collect them all
        let allData = await dataStack.getAll()
        var matchingFrames: [Frame] = []

        // Extract the base stepLinkID (e.g., "step.output" from "step[0].output" or just "step.output")
        let baseStepLinkID: String
        if stepLinkID.contains("[") {
            // If stepLinkID has an index, extract the base (but this shouldn't happen for merge inputs)
            baseStepLinkID = String(stepLinkID.split(separator: "[").first!)
        } else {
            baseStepLinkID = stepLinkID
        }

        for data in allData {
            if let frame = data as? Frame,
               let outputLink = frame.outputLink,
               case .output(_, _, _, let frameStepLinkID) = outputLink {
                // Extract base from frame's stepLinkID (might be "step[0].output")
                let frameBaseStepLinkID: String
                if frameStepLinkID.contains("[") {
                    // Extract base and output name: "step[0].output" -> "step.output"
                    let parts = frameStepLinkID.split(separator: "[")
                    if parts.count > 0 {
                        let basePart = String(parts[0])
                        // Find the output name after the index
                        if let dotIndex = frameStepLinkID.firstIndex(of: ".") {
                            let afterDot = String(frameStepLinkID[frameStepLinkID.index(after: dotIndex)...])
                            frameBaseStepLinkID = "\(basePart).\(afterDot)"
                        } else {
                            frameBaseStepLinkID = basePart
                        }
                    } else {
                        frameBaseStepLinkID = frameStepLinkID
                    }
                } else {
                    frameBaseStepLinkID = frameStepLinkID
                }

                // Match on base stepLinkID
                if frameBaseStepLinkID == baseStepLinkID {
                    matchingFrames.append(frame)
                }
            }
        }

        if matchingFrames.isEmpty {
            return nil
        }

        // Create a FrameSet from the matching frames
        // The FrameSet's outputLink should reference the stepLinkID that will consume it
        let frameSet = FrameSet(
            frames: matchingFrames,
            outputProcess: (
                id: UUID(), // Synthetic process ID for the merge
                name: linkName,
                stepLinkID: stepLinkID
            ),
            inputProcesses: []
        )

        // Add the synthesized FrameSet to the data stack
        await dataStack.add(data: frameSet)

        Logger.pipeline.info("Synthesized FrameSet '\(linkName)' from \(matchingFrames.count) frames with base stepLinkID '\(baseStepLinkID)'")

        return frameSet
    }

    /// Synthesizes a TableSet from individual tables that share the same base stepLinkID.
    /// Mirrors synthesizeFrameSetFromFrames for the table collection case.
    private func synthesizeTableSetFromTables(stepLinkID: String, linkName: String) async -> TableSet? {
        let allData = await dataStack.getAll()
        var matchingTables: [(index: Int, table: TableData)] = []

        let baseStepLinkID: String
        if stepLinkID.contains("[") {
            baseStepLinkID = String(stepLinkID.split(separator: "[").first ?? Substring(stepLinkID))
        } else {
            baseStepLinkID = stepLinkID
        }

        for data in allData {
            guard let table = data as? TableData,
                  let outputLink = table.outputLink,
                  case .output(_, _, _, let tableStepLinkID) = outputLink else { continue }

            let tableBaseStepLinkID: String
            var frameIndex = 0
            if tableStepLinkID.contains("[") {
                let parts = tableStepLinkID.split(separator: "[")
                let basePart = String(parts[0])
                if let bracketEnd = tableStepLinkID.firstIndex(of: "]"),
                   let bracketStart = tableStepLinkID.firstIndex(of: "[") {
                    let idxStr = tableStepLinkID[tableStepLinkID.index(after: bracketStart)..<bracketEnd]
                    frameIndex = Int(idxStr) ?? 0
                }
                if let dotIndex = tableStepLinkID.firstIndex(of: ".") {
                    let afterDot = String(tableStepLinkID[tableStepLinkID.index(after: dotIndex)...])
                    tableBaseStepLinkID = "\(basePart).\(afterDot)"
                } else {
                    tableBaseStepLinkID = basePart
                }
            } else {
                tableBaseStepLinkID = tableStepLinkID
            }

            if tableBaseStepLinkID == baseStepLinkID {
                matchingTables.append((index: frameIndex, table: table))
            }
        }

        if matchingTables.isEmpty { return nil }

        let sortedTables = matchingTables.sorted { $0.index < $1.index }.map { $0.table }
        let tableSet = TableSet(
            tables: sortedTables,
            outputProcess: (id: UUID(), name: linkName, stepLinkID: stepLinkID),
            inputProcesses: []
        )
        await dataStack.add(data: tableSet)
        Logger.pipeline.info("Synthesized TableSet '\(linkName)' from \(sortedTables.count) tables with base stepLinkID '\(baseStepLinkID)'")
        return tableSet
    }

    /// Prepares input data for a process from the data stack
    /// - Parameter process: The process to prepare inputs for
    /// - Returns: Dictionary of input name to ProcessData
    /// - Throws: ProcessorExecutionError if required input is missing
    private func prepareProcessInputs(process: Process) async throws -> [String: ProcessData] {
        var inputs: [String: ProcessData] = [:]
        for inputLink in process.inputData {
            if case .input(_, let linkName, let type, let collectionMode, let stepLinkID) = inputLink {
                if let data = await dataStack.get(by: inputLink) {
                    inputs[linkName] = data
                } else if type == .frameSet && collectionMode == .together {
                    // Try to synthesize a FrameSet from individual frames with the same stepLinkID
                    if let synthesizedFrameSet = await synthesizeFrameSetFromFrames(stepLinkID: stepLinkID, linkName: linkName) {
                        inputs[linkName] = synthesizedFrameSet
                    } else {
                        throw ProcessorExecutionError.missingRequiredInput(linkName)
                    }
                } else if type == .tableSet && collectionMode == .together {
                    // Try to synthesize a TableSet from individual tables with the same stepLinkID
                    if let synthesizedTableSet = await synthesizeTableSetFromTables(stepLinkID: stepLinkID, linkName: linkName) {
                        inputs[linkName] = synthesizedTableSet
                    } else {
                        throw ProcessorExecutionError.missingRequiredInput(linkName)
                    }
                } else {
                    throw ProcessorExecutionError.missingRequiredInput(linkName)
                }
            }
        }
        return inputs
    }

    /// Prepares output data instances for a process from the data stack
    /// - Parameter process: The process to prepare outputs for
    /// - Returns: Dictionary of output name to ProcessData
    /// - Throws: ProcessorExecutionError if output data is not found
    private func prepareProcessOutputs(process: Process) async throws -> [String: ProcessData] {
        var outputs: [String: ProcessData] = [:]
        for outputLink in process.outputData {
            if case .output(_, let linkName, _, _) = outputLink {
                if let outputData = await dataStack.get(by: outputLink) {
                    outputs[linkName] = outputData
                } else {
                    throw ProcessorExecutionError.executionFailed(
                        "Output data not found for link: \(linkName)"
                    )
                }
            }
        }
        return outputs
    }

    /// Updates the data stack with instantiated output data from a process
    /// - Parameter outputs: Dictionary of output name to ProcessData
    private func updateProcessOutputs(outputs: [String: ProcessData]) async {
        for (outputName, outputData) in outputs {
            let wasUpdated = await dataStack.update(data: outputData)
            if wasUpdated {
                Logger.pipeline.debug("Updated output '\(outputName)' in data stack (instantiated: \(outputData.isInstantiated))")
            } else {
                Logger.pipeline.warning("Failed to update output '\(outputName)' in data stack")
            }
        }
    }

    /// Executes a single process
    /// - Parameters:
    ///   - process: The process to execute
    ///   - device: Metal device for GPU operations
    ///   - commandQueue: Metal command queue for GPU operations
    ///   - registry: Processor registry to look up the processor
    /// - Throws: ProcessorExecutionError if execution fails
    private func executeProcess(
        process: Process,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        registry: ProcessorRegistry
    ) async throws {
        let processorID = process.processorIdentifier
        guard let processor = await registry.get(id: processorID) else {
            throw ProcessorExecutionError.processorNotFound(processorID)
        }

        // Mark process as running
        var runningProcess = process
        runningProcess.markAsRunning()
        await processStack.update(process: runningProcess)

        do {
            // Prepare inputs and outputs
            let inputs = try await prepareProcessInputs(process: runningProcess)
            var outputs = try await prepareProcessOutputs(process: runningProcess)

            // Execute the processor (outputs are passed as inout to be instantiated)
            try processor.execute(
                inputs: inputs,
                outputs: &outputs,
                parameters: runningProcess.parameters,
                device: device,
                commandQueue: commandQueue
            )

            // Update data stack with instantiated outputs
            await updateProcessOutputs(outputs: outputs)

            // Mark process as completed
            runningProcess.markAsCompleted()
            await processStack.update(process: runningProcess)

            Logger.pipeline.info("Completed process: \(runningProcess.stepIdentifier)")
        } catch {
            // Mark process as failed
            runningProcess.markAsFailed(error: error)
            await processStack.update(process: runningProcess)
            throw error
        }
    }

    /// Checks if pipeline should complete after an iteration with no progress
    /// - Parameters:
    ///   - processesWithoutProcessors: Processes that don't have processors
    ///   - executedProcessIDs: Set of already executed process IDs
    /// - Returns: True if pipeline should continue, false if it should complete
    private func checkIterationCompletion(
        processesWithoutProcessors: [Process],
        executedProcessIDs: Set<UUID>
    ) async -> Bool {
        let totalProcesses = await processStack.count()
        let pendingCount = await processStack.getPending().count
        Logger.pipeline.debug("No processes executed this iteration. Status: \(executedProcessIDs.count) executed, \(pendingCount) pending, \(totalProcesses) total")

        if pendingCount == 0 {
            Logger.pipeline.info("All processes completed.")
            return false
        } else if processesWithoutProcessors.count == pendingCount {
            Logger.pipeline.info("All remaining processes have no processors. Pipeline complete.")
            return false
        } else {
            Logger.pipeline.warning("Pipeline may be stuck - processes are pending but not ready.")
            return false
        }
    }

    /// Preconfigure all pipeline processes by creating Process instances,
    /// setting up input/output data links, and creating placeholder output data.
    /// This method sets up the process and data structures before execution begins.
    private func preconfigureProcesses(pipelineParameters: [String: Parameter] = [:]) async throws {
        for step in pipeline.steps {
            // Resolve parameters for this step
            let resolvedParameters = resolveStepParameters(
                step: step,
                pipelineParameters: pipelineParameters
            )

            // Create process for this step
            let process = try createProcessForStep(
                step: step,
                parameters: resolvedParameters
            )
            await processStack.add(process: process)

            // Set up input links for ProcessData
            await setupProcessInputLinks(process: process)

            // Create output data and add to data stack
            try await createProcessOutputData(process: process)
        }
    }

    /// Resolves parameters for a step from pipeline parameters and defaults
    /// - Parameters:
    ///   - step: The pipeline step to resolve parameters for
    ///   - pipelineParameters: Dictionary of pipeline-level parameters
    /// - Returns: Dictionary of resolved parameter names to values
    private func resolveStepParameters(
        step: PipelineStep,
        pipelineParameters: [String: Parameter]
    ) -> [String: Parameter] {
        var resolvedParameters: [String: Parameter] = [:]
        for paramSpec in step.parameters {
            if let fromName = paramSpec.from, let paramValue = pipelineParameters[fromName] {
                // Parameter value comes from pipeline parameters
                resolvedParameters[paramSpec.name] = paramValue
            } else if let defaultValue = paramSpec.defaultValue {
                // Use default value from ParameterSpec
                resolvedParameters[paramSpec.name] = defaultValue
            }
            // If neither from nor defaultValue is set, the parameter is omitted
        }
        return resolvedParameters
    }

    /// Creates a Process instance for a pipeline step
    /// Note: Collection splitting happens at execution time, not at configuration time
    /// - Parameters:
    ///   - step: The pipeline step
    ///   - parameters: Resolved parameters for the step
    /// - Returns: A Process instance
    private func createProcessForStep(
        step: PipelineStep,
        parameters: [String: Parameter]
    ) throws -> Process {
        // Extract input data tuples from step
        // Note: Using tuple format that Process.init expects
        let inputDataTuples = step.dataInputs.map { dataInput in
            let collectionMode = dataInput.collectionMode ?? .individually
            let stepLinkID: String
            if dataInput.from.contains(".") {
                stepLinkID = dataInput.from
            } else {
                stepLinkID = "initial.\(dataInput.from)"
            }
            return (dataInput.name, dataInput.type, collectionMode, stepLinkID)
        }

        // Extract output data tuples from step
        let outputDataTuples: [(String, DataType)] = step.outputs.map { output in
            (output.name, output.type)
        }

        return Process(
            stepIdentifier: step.id,
            processorIdentifier: step.type,
            inputData: inputDataTuples,
            parameters: parameters,
            outputData: outputDataTuples
        )
    }

    /// Sets up input links for ProcessData that is referenced by a process
    /// - Parameter process: The process to set up input links for
    private func setupProcessInputLinks(process: Process) async {
        for inputLink in process.inputData {
            if case .input(let processId, let linkName, let type, let collectionMode, let stepLinkID) = inputLink {
                guard var processData = await dataStack.get(
                    by: .input(
                        process: processId,
                        link: linkName,
                        type: type,
                        collectionMode: collectionMode,
                        stepLinkID: stepLinkID
                    )
                ) else {
                        continue
                    }
                processData.addInputLink(
                    process: process.identifier,
                    link: linkName,
                    collectionMode: collectionMode
                )
                _ = await dataStack.update(data: processData)
            }
        }
    }

    /// Creates output data for a process and adds it to the data stack
    /// - Parameter process: The process to create output data for
    /// - Throws: PipelineConfigurationError if output data creation fails
    private func createProcessOutputData(process: Process) async throws {
        for outputLink in process.outputData {
            if case .output(_, _, let type, _) = outputLink {
                if let outputData = try self.createOutputData(
                    type: type,
                    outputLink: outputLink
                ) {
                    await dataStack.add(data: outputData)
                }
            }
        }
    }   

    private func createInitialInputData(
        from inputs: [String: Any],
        device: MTLDevice,
        initialProcess: Process,
        dataStack: DataStack
    ) async throws {
        // Create the initial input data for the pipeline.
        Logger.pipeline.debug("Creating initial input data for the pipeline")
        
        // Collect expected input names from pipeline steps (where 'from' doesn't contain a dot)
        let expectedInputNames = Set(pipeline.steps.flatMap { step in
            step.dataInputs.compactMap { dataInput in
                // If 'from' doesn't contain a dot, it's a pipeline input
                if !dataInput.from.contains(".") {
                    return dataInput.from
                }
                return nil
            }
        })
        
        // Validate that provided inputs match expected names
        let providedInputNames = Set(inputs.keys)
        if providedInputNames != expectedInputNames {
            let missing = expectedInputNames.subtracting(providedInputNames)
            let extra = providedInputNames.subtracting(expectedInputNames)
            var errorMsg = "Input name mismatch. "
            if !missing.isEmpty {
                errorMsg += "Missing inputs: \(missing.joined(separator: ", ")). "
            }
            if !extra.isEmpty {
                errorMsg += "Unexpected inputs: \(extra.joined(separator: ", ")). "
            }
            errorMsg += "Expected: \(expectedInputNames.sorted().joined(separator: ", ")). Provided: \(providedInputNames.sorted().joined(separator: ", "))"
            Logger.pipeline.error("\(errorMsg)")
            throw ProcessorExecutionError.executionFailed(errorMsg)
        }
        
        for (key, value) in inputs {
            // Infer data type from the input value
            let dataType: DataType
            if value is Frame {
                dataType = .frame
            } else if value is FrameSet {
                dataType = .frameSet
            } else if value is FITSImage {
                dataType = .frame // FITSImage becomes a Frame
            } else {
                Logger.pipeline.error("Cannot infer data type for input: \(type(of: value))")
                fatalError("Cannot infer data type for input: \(type(of: value))")
            }
            
            // For initial input data, stepLinkID follows the pattern "initial.input_name"
            // Use the key which should now match the expected input name from the pipeline
            let stepLinkID = "initial.\(key)"
            let inputData = try self.createInputData(
                from: value,
                device: device,
                outputProcess: .output(
                    process: initialProcess.identifier,
                    link: key,
                    type: dataType,
                    stepLinkID: stepLinkID
                )
            )
            Logger.pipeline.debug("Created input data \(inputData.identifier) with stepLinkID: \(stepLinkID)")
            await dataStack.add(data: inputData)
        }
    }

    private func createInputData(
        from input: Any,
        device: MTLDevice,
        outputProcess: ProcessDataLink
    ) throws -> ProcessData {
        if var frame = input as? Frame {
            Logger.pipeline.debug("Creating frame input data")
            frame.outputLink = outputProcess
            return frame
        } else if var frameSet = input as? FrameSet {
            Logger.pipeline.debug("Creating frame set input data")
            frameSet.outputLink = outputProcess
            return frameSet
        } else if let fitsImage = input as? FITSImage {
            Logger.pipeline.debug("Creating FITS image input data")
            return try Frame(
                fitsImage: fitsImage,
                device: device,
                outputProcess: outputProcess,
                inputProcesses: []
            )
        } else {
            Logger.pipeline.error("Unsupported input type: \(type(of: input))")
            fatalError("Unsupported input type: \(type(of: input))")
        }
    }

    private func createOutputData(
        type: DataType,
        outputLink: ProcessDataLink
    ) throws -> ProcessData? { // TODO: Should never be nil when all types are supported.
        switch type {
        case .frame:
            Logger.pipeline.debug("Creating frame output data placeholder")
            // Create a placeholder Frame without texture (not instantiated yet)
            return Frame(
                type: .light, // Default, will be updated when process executes
                filter: .none,
                colorSpace: .greyscale, // Default, will be updated when process executes
                dataType: .float, // Default, will be updated when process executes
                texture: nil, // Not instantiated yet
                outputProcess: outputLink,
                inputProcesses: []
            )
        case .frameSet:
            Logger.pipeline.debug("Creating frame set output data placeholder")
            // Create a placeholder FrameSet (empty collection)
            // Extract process ID, link name, and stepLinkID from outputLink
            if case .output(let processId, let linkName, _, let stepLinkID) = outputLink {
                return FrameSet(
                    frames: [],
                    outputProcess: (id: processId, name: linkName, stepLinkID: stepLinkID),
                    inputProcesses: []
                )
            } else {
                fatalError("Output link must be an output case")
            }
        case .table:
            Logger.pipeline.debug("Creating table output data placeholder")
            // Create a placeholder TableData without DataFrame (not instantiated yet)
            return TableData(
                dataFrame: nil, // Not instantiated yet
                outputProcess: outputLink,
                inputProcesses: []
            )
        case .tableSet:
            Logger.pipeline.debug("Creating table set output data placeholder")
            if case .output(let processId, let linkName, _, let stepLinkID) = outputLink {
                return TableSet(
                    tables: [],
                    outputProcess: (id: processId, name: linkName, stepLinkID: stepLinkID),
                    inputProcesses: []
                )
            } else {
                fatalError("Output link must be an output case")
            }
        }
    }
}

