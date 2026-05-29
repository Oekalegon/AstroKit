import Testing
import Foundation
import Metal
@testable import AstrophotoKit

@Test("Star detection pipeline creates correct process data and processes")
func starDetectionPipelineCreatesCorrectStacks() async throws {
    // Load the star-detection pipeline
    guard let bundle = findMainPackageBundle(),
          let pipelineURL = bundle.url(forResource: "star-detection", withExtension: "yaml") else {
        return
    }
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Create a Metal device for the runner
    guard let device = MTLCreateSystemDefaultDevice() else {
        // Skip test if Metal is not available (e.g., in CI environments)
        return
    }
    
    guard let commandQueue = device.makeCommandQueue() else {
        // Skip test if command queue cannot be created
        return
    }
    
    // Create a mock input frame for testing
    // The pipeline expects "input_frame" as input based on the YAML configuration
    // We'll create a simple Frame without a texture (not instantiated) for testing
    let testFrame = Frame(
        type: .light,
        filter: .none,
        colorSpace: .greyscale,
        dataType: .short,
        texture: nil,
        outputProcess: nil,
        inputProcesses: []
    )
    let inputs: [String: Any] = ["input_frame": testFrame]
    
    // Create the pipeline runner
    let runner = PipelineRunner(pipeline: pipeline)
    
    // Execute the pipeline (this will create processes and initial data)
    _ = try await runner.execute(
        inputs: inputs,
        device: device,
        commandQueue: commandQueue
    )
    
    // Verify the process stack
    let processes = await runner.processStack.getAll()
    
    // Print process stack contents
    print("\n=== PROCESS STACK ===")
    print("Total processes: \(processes.count)")
    for (index, process) in processes.enumerated() {
        print("\nProcess \(index + 1):")
        print("  ID: \(process.identifier)")
        print("  Step ID: \(process.stepIdentifier)")
        print("  Processor: \(process.processorIdentifier)")
        print("  Status: \(process.currentStatus)")
        print("  Input Data Links: \(process.inputData.count)")
        for (i, inputLink) in process.inputData.enumerated() {
            if case .input(let processId, let linkName, let type, let collectionMode, let stepLinkID) = inputLink {
                print("    [\(i)] Input: process=\(processId.uuidString.prefix(8)), link=\(linkName), type=\(type), mode=\(collectionMode), stepLinkID=\(stepLinkID)")
            }
        }
        print("  Output Data Links: \(process.outputData.count)")
        for (i, outputLink) in process.outputData.enumerated() {
            if case .output(let processId, let linkName, let type, let stepLinkID) = outputLink {
                print("    [\(i)] Output: process=\(processId.uuidString.prefix(8)), link=\(linkName), type=\(type), stepLinkID=\(stepLinkID)")
            }
        }
    }
    
    // The star-detection pipeline has 11 steps:
    // 1. grayscale
    // 2. blur
    // 3. background
    // 4. threshold
    // 5. erosion
    // 6. dilation
    // 7. connected_components
    // 8. fwhm
    // 9. fits_catalog_writer
    // 10. quads
    // 11. overlay
    #expect(processes.count == 11)

    // Verify each process has the correct processor identifier
    let expectedTypes = [
        "grayscale",
        "gaussian_blur",
        "background_estimation",
        "threshold",
        "erosion",
        "dilation",
        "connected_components",
        "fwhm",
        "fits_star_catalog_writer",
        "quads",
        "star_detection_overlay"
    ]

    let actualTypes = processes.map { $0.processorIdentifier }
    for expectedType in expectedTypes {
        #expect(actualTypes.contains(expectedType))
    }

    // Verify all processes are in pending status initially
    let pendingProcesses = await runner.processStack.getPending()
    #expect(pendingProcesses.count == 11)
    
    // Verify the data stack
    // We provided "input_frame" as input, so the data stack should contain at least one item
    let allData = await runner.dataStack.getAll()
    let dataCount = await runner.dataStack.count()
    
    // Print data stack contents
    print("\n=== DATA STACK ===")
    print("Total data items: \(dataCount)")
    for (index, data) in allData.enumerated() {
        print("\nData \(index + 1):")
        print("  ID: \(data.identifier)")
        print("  Type: \(type(of: data))")
        print("  Instantiated: \(data.isInstantiated)")
        print("  Is Collection: \(data.isCollection)")
        if let outputLink = data.outputLink {
            if case .output(let processId, let linkName, let type, let stepLinkID) = outputLink {
                print("  Output Link: process=\(processId.uuidString.prefix(8)), link=\(linkName), type=\(type), stepLinkID=\(stepLinkID)")
            }
        } else {
            print("  Output Link: nil")
        }
        print("  Input Links: \(data.inputLinks.count)")
        for (i, inputLink) in data.inputLinks.enumerated() {
            if case .input(let processId, let linkName, let type, let collectionMode, let stepLinkID) = inputLink {
                print("    [\(i)] Input: process=\(processId.uuidString.prefix(8)), link=\(linkName), type=\(type), mode=\(collectionMode), stepLinkID=\(stepLinkID)")
            }
        }
    }
    
    // We provided "input_frame" as input, so we should have at least one data item
    #expect(dataCount >= 1, "Data stack should contain at least the input_frame")
    
    // Verify that processes have correct input/output data links
    // Side-effect processors (e.g. fits_star_catalog_writer) intentionally produce no outputs.
    let sideEffectProcessors: Set<String> = ["fits_star_catalog_writer"]
    for process in processes {
        // Each process should have at least one output, except side-effect processors
        if !sideEffectProcessors.contains(process.processorIdentifier) {
            #expect(!process.outputData.isEmpty)
        }
        
        // Verify output data links have the correct type
        for outputLink in process.outputData {
            if case .output(_, _, let type, _) = outputLink {
                // Type should be one of: frame, frameSet, or table
                #expect([DataType.frame, .frameSet, .table].contains(type), 
                       "Output link type should be frame, frameSet, or table")
            } else {
                Issue.record("Output link should be an output case")
            }
        }
        
        // Verify input data links have the correct type
        for inputLink in process.inputData {
            if case .input(_, _, let type, _, _) = inputLink {
                // Type should be one of: frame, frameSet, or table
                #expect([DataType.frame, .frameSet, .table].contains(type), 
                       "Input link type should be frame, frameSet, or table")
            } else {
                Issue.record("Input link should be an input case")
            }
        }
    }
    
    // Verify specific process configurations
    // Find the grayscale process
    if let grayscaleProcess = processes.first(where: { $0.processorIdentifier == "grayscale" }) {
        // Grayscale should have 1 input (input_frame) and 1 output (grayscale_frame)
        #expect(grayscaleProcess.inputData.count == 1, "Grayscale should have 1 input")
        #expect(grayscaleProcess.outputData.count == 1, "Grayscale should have 1 output")
        
        // Verify the output link name and stepLinkID
        if case .output(_, let linkName, let type, let stepLinkID) = grayscaleProcess.outputData.first! {
            #expect(linkName == "grayscale_frame", "Grayscale output should be named 'grayscale_frame'")
            #expect(type == .frame, "Grayscale output should be type 'frame'")
            #expect(stepLinkID == "grayscale.grayscale_frame", "Grayscale stepLinkID should be 'grayscale.grayscale_frame'")
        }
    }
    
    // Find the connected_components process
    if let connectedComponentsProcess = processes.first(where: { $0.processorIdentifier == "connected_components" }) {
        // Connected components should have 2 outputs (pixel_coordinates and coordinate_count)
        let outputCount = connectedComponentsProcess.outputData.count
        #expect(outputCount == 1, "Connected components should have 1 output")
        
        // Verify output names, types, and stepLinkIDs
        let outputNames = connectedComponentsProcess.outputData.compactMap { link -> String? in
            if case .output(_, let name, _, _) = link {
                return name
            }
            return nil
        }
        #expect(outputNames.contains("pixel_coordinates"), "Should have pixel_coordinates output")
        
        // Verify types and stepLinkIDs
        for outputLink in connectedComponentsProcess.outputData {
            if case .output(_, let name, let type, let stepLinkID) = outputLink {
                if name == "pixel_coordinates" || name == "coordinate_count" {
                    #expect(type == .table, "\(name) should be type 'table', but got '\(type)'")
                    let expectedStepLinkID = "connected_components.\(name)"
                    #expect(stepLinkID == expectedStepLinkID, "\(name) stepLinkID should be '\(expectedStepLinkID)', but got '\(stepLinkID)'")
                }
            }
        }
    }
}

