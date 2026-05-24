import Testing
import Foundation
import Metal
@testable import AstrophotoKit

@Test("Star detection pipeline runs all steps including overlay")
func testStarDetectionPipelineWithOverlay() async throws {
    // Get Metal device
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal device not available")
        return
    }

    guard let commandQueue = device.makeCommandQueue() else {
        Issue.record("Could not create Metal command queue")
        return
    }

    // Load the star-detection pipeline
    guard let bundle = findMainPackageBundle(),
          let pipelineURL = bundle.url(forResource: "star-detection", withExtension: "yaml") else {
        return
    }
    let pipeline = try Pipeline.load(from: pipelineURL)

    // Load a FITS file from test resources
    // FITS files are in the test bundle, not the main bundle
    let fitsFileName = "CHI-1-CMOS_2025-03-25T08-25-40_LDN43TheCosmicBatNebula_Luminance_300s_ID493996_cal"
    var resourceURL: URL?
    // Try test bundle first
    if let testBundle = Bundle.module as Bundle? {
        resourceURL = testBundle.url(forResource: fitsFileName, withExtension: "fits")
    }
    // Fallback: try all bundles
    if resourceURL == nil {
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: fitsFileName, withExtension: "fits") {
                resourceURL = url
                break
            }
        }
    }
    guard let resourceURL = resourceURL else {
        return
    }

    // Open FITS file and read image
    let fitsFile = try FITSFile(path: resourceURL.path)
    let fitsImage = try fitsFile.readFITSImage()

    // Create Frame from FITS image
    let inputFrame = try Frame(fitsImage: fitsImage, device: device)

    // Verify input frame has texture
    #expect(inputFrame.texture != nil, "Input frame should have a texture")
    let inputTexture = inputFrame.texture!
    print("Input frame: \(inputTexture.width)x\(inputTexture.height), format: \(inputTexture.pixelFormat)")

    // Create the pipeline runner
    let runner = PipelineRunner(pipeline: pipeline)

    // Execute the pipeline with the input frame
    // Processors are automatically registered when first accessed
    let outputs = try await runner.execute(
        inputs: ["input_frame": inputFrame],
        parameters: ["blur_radius": Parameter.double(3.0)],
        device: device,
        commandQueue: commandQueue
    )

    print("\n=== Pipeline Execution Results ===")
    print("Number of output data items: \(outputs.count)")

    // Verify we have output data
    #expect(!outputs.isEmpty, "Pipeline should produce output data")

    // Check for grayscale_frame output (from first step)
    // Find data by stepLinkID: "grayscale.grayscale_frame"
    let grayscaleData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "grayscale.grayscale_frame"
        }
        return false
    }
    #expect(grayscaleData != nil, "Should have grayscale_frame output")
    if let grayscaleFrame = grayscaleData as? Frame {
        #expect(grayscaleFrame.texture != nil, "Grayscale frame should be instantiated")
        #expect(grayscaleFrame.isInstantiated, "Grayscale frame should be instantiated")
        #expect(grayscaleFrame.colorSpace == ColorSpace.greyscale, "Grayscale frame should have greyscale color space")
        print("✓ Grayscale frame: \(grayscaleFrame.texture!.width)x\(grayscaleFrame.texture!.height)")
    }

    // Check for blurred_frame output (from second step)
    // Find data by stepLinkID: "blur.blurred_frame"
    let blurredData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "blur.blurred_frame"
        }
        return false
    }
    #expect(blurredData != nil, "Should have blurred_frame output")
    if let blurredFrame = blurredData as? Frame {
        #expect(blurredFrame.texture != nil, "Blurred frame should be instantiated")
        #expect(blurredFrame.isInstantiated, "Blurred frame should be instantiated")
        print("✓ Blurred frame: \(blurredFrame.texture!.width)x\(blurredFrame.texture!.height)")
    }

    // Check for background_frame output (from third step)
    // Find data by stepLinkID: "background.background_frame"
    let backgroundData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "background.background_frame"
        }
        return false
    }
    #expect(backgroundData != nil, "Should have background_frame output")
    if let backgroundFrame = backgroundData as? Frame {
        #expect(backgroundFrame.texture != nil, "Background frame should be instantiated")
        #expect(backgroundFrame.isInstantiated, "Background frame should be instantiated")
        print("✓ Background frame: \(backgroundFrame.texture!.width)x\(backgroundFrame.texture!.height)")
    }

    // Check for background_subtracted_frame output (from third step)
    // Find data by stepLinkID: "background.background_subtracted_frame"
    let subtractedData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "background.background_subtracted_frame"
        }
        return false
    }
    #expect(subtractedData != nil, "Should have background_subtracted_frame output")
    if let subtractedFrame = subtractedData as? Frame {
        #expect(subtractedFrame.texture != nil, "Background-subtracted frame should be instantiated")
        #expect(subtractedFrame.isInstantiated, "Background-subtracted frame should be instantiated")
        print("✓ Background-subtracted frame: \(subtractedFrame.texture!.width)x\(subtractedFrame.texture!.height)")
    }

    // Check for background_level table output (from third step)
    // Find data by stepLinkID: "background.background_level"
    let backgroundLevelData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "background.background_level"
        }
        return false
    }
    #expect(backgroundLevelData != nil, "Should have background_level output")
    if let backgroundLevelTable = backgroundLevelData as? TableData {
        #expect(backgroundLevelTable.isInstantiated, "Background level table should be instantiated")
        #expect(backgroundLevelTable.dataFrame != nil, "Background level table should have DataFrame")
        #expect(backgroundLevelTable.rowCount == 1, "Background level table should have 1 row")
        #expect(backgroundLevelTable.columnCount == 1, "Background level table should have 1 column")
        print("✓ Background level table: \(backgroundLevelTable.rowCount) row(s), " +
              "\(backgroundLevelTable.columnCount) column(s)")
    }

    // Check for thresholded_frame output (from fourth step)
    // Find data by stepLinkID: "threshold.thresholded_frame"
    let thresholdedData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "threshold.thresholded_frame"
        }
        return false
    }
    #expect(thresholdedData != nil, "Should have thresholded_frame output")
    if let thresholdedFrame = thresholdedData as? Frame {
        #expect(thresholdedFrame.texture != nil, "Thresholded frame should be instantiated")
        #expect(thresholdedFrame.isInstantiated, "Thresholded frame should be instantiated")
        print("✓ Thresholded frame: \(thresholdedFrame.texture!.width)x\(thresholdedFrame.texture!.height)")
    }

    // Verify process stack
    let processes = await runner.processStack.getAll()
    print("\n=== Process Stack ===")
    print("Total processes: \(processes.count)")

    // Check for eroded_frame output (from fifth step)
    // Find data by stepLinkID: "erosion.eroded_frame"
    let erodedData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "erosion.eroded_frame"
        }
        return false
    }
    #expect(erodedData != nil, "Should have eroded_frame output")
    if let erodedFrame = erodedData as? Frame {
        #expect(erodedFrame.texture != nil, "Eroded frame should be instantiated")
        #expect(erodedFrame.isInstantiated, "Eroded frame should be instantiated")
        print("✓ Eroded frame: \(erodedFrame.texture!.width)x\(erodedFrame.texture!.height)")
    }

    // Check for dilated_frame output (from sixth step)
    // Find data by stepLinkID: "dilation.dilated_frame"
    let dilatedData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "dilation.dilated_frame"
        }
        return false
    }
    #expect(dilatedData != nil, "Should have dilated_frame output")
    if let dilatedFrame = dilatedData as? Frame {
        #expect(dilatedFrame.texture != nil, "Dilated frame should be instantiated")
        #expect(dilatedFrame.isInstantiated, "Dilated frame should be instantiated")
        print("✓ Dilated frame: \(dilatedFrame.texture!.width)x\(dilatedFrame.texture!.height)")
    }

    // Check for pixel_coordinates table output (from seventh step)
    // Find data by stepLinkID: "connected_components.pixel_coordinates"
    let pixelCoordinatesData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "connected_components.pixel_coordinates"
        }
        return false
    }
    #expect(pixelCoordinatesData != nil, "Should have pixel_coordinates output")
    if let pixelCoordinatesTable = pixelCoordinatesData as? TableData {
        #expect(pixelCoordinatesTable.isInstantiated, "Pixel coordinates table should be instantiated")
        #expect(pixelCoordinatesTable.dataFrame != nil, "Pixel coordinates table should have DataFrame")
        print("✓ Pixel coordinates table: \(pixelCoordinatesTable.rowCount) row(s), " +
              "\(pixelCoordinatesTable.columnCount) column(s)")
        if let dataFrame = pixelCoordinatesTable.dataFrame {
            print("  Columns: \(pixelCoordinatesTable.columnNames.joined(separator: ", "))")

            // Print first 20 rows using DataFrame's description
            // TabularData's DataFrame has a description property that formats the table nicely
            let rowsToPrint = min(20, dataFrame.rows.count)
            if rowsToPrint > 0 {
                // Create a subset DataFrame with first N rows
                let subsetDF = dataFrame[0..<rowsToPrint]
                print("\n  First \(rowsToPrint) rows (sorted by area, descending):")
                print(subsetDF.description)
            }
        }
    }

    // Check for quads table output (from eighth step)
    // Find data by stepLinkID: "quads.quads"
    let quadsData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "quads.quads"
        }
        return false
    }
    #expect(quadsData != nil, "Should have quads output")
    if let quadsTable = quadsData as? TableData {
        #expect(quadsTable.isInstantiated, "Quads table should be instantiated")
        #expect(quadsTable.dataFrame != nil, "Quads table should have DataFrame")
        print("✓ Quads table: \(quadsTable.rowCount) row(s), \(quadsTable.columnCount) column(s)")
        if let dataFrame = quadsTable.dataFrame {
            print("  Columns: \(quadsTable.columnNames.joined(separator: ", "))")

            // Print first 10 rows using DataFrame's description
            let rowsToPrint = min(10, dataFrame.rows.count)
            if rowsToPrint > 0 {
                // Create a subset DataFrame with first N rows
                let subsetDF = dataFrame[0..<rowsToPrint]
                print("\n  First \(rowsToPrint) quads:")
                print(subsetDF.description)
            }
        }
    }

    // Check for annotated_frame output (from overlay step)
    // Find data by stepLinkID: "overlay.annotated_frame"
    let annotatedData = outputs.first { data in
        if case .output(_, _, _, let stepLinkID) = data.outputLink {
            return stepLinkID == "overlay.annotated_frame"
        }
        return false
    }
    #expect(annotatedData != nil, "Should have annotated_frame output")
    var annotatedFrame: Frame?
    if let frame = annotatedData as? Frame {
        #expect(frame.texture != nil, "Annotated frame should be instantiated")
        #expect(frame.isInstantiated, "Annotated frame should be instantiated")
        annotatedFrame = frame
        print("✓ Annotated frame: \(frame.texture!.width)x\(frame.texture!.height)")
    }

    // Check that all processes exist and have completed
    let grayscaleProcess = processes.first { $0.stepIdentifier == "grayscale" }
    let blurProcess = processes.first { $0.stepIdentifier == "blur" }
    let backgroundProcess = processes.first { $0.stepIdentifier == "background" }
    let thresholdProcess = processes.first { $0.stepIdentifier == "threshold" }
    let erosionProcess = processes.first { $0.stepIdentifier == "erosion" }
    let dilationProcess = processes.first { $0.stepIdentifier == "dilation" }
    let connectedComponentsProcess = processes.first { $0.stepIdentifier == "connected_components" }
    let quadsProcess = processes.first { $0.stepIdentifier == "quads" }
    let overlayProcess = processes.first { $0.stepIdentifier == "overlay" }

    #expect(grayscaleProcess != nil, "Should have grayscale process")
    #expect(blurProcess != nil, "Should have blur process")
    #expect(backgroundProcess != nil, "Should have background process")
    #expect(thresholdProcess != nil, "Should have threshold process")
    #expect(erosionProcess != nil, "Should have erosion process")
    #expect(dilationProcess != nil, "Should have dilation process")
    #expect(connectedComponentsProcess != nil, "Should have connected_components process")
    #expect(quadsProcess != nil, "Should have quads process")
    #expect(overlayProcess != nil, "Should have overlay process")

    // Verify all processes have completed
    let allProcesses = [grayscaleProcess, blurProcess, backgroundProcess, thresholdProcess,
                        erosionProcess, dilationProcess, connectedComponentsProcess,
                        quadsProcess, overlayProcess].compactMap { $0 }
    #expect(allProcesses.count == 9, "Should have 9 processes")

    for process in allProcesses {
        let isCompleted = process.statusHistory.contains { status in
            if case .completed = status {
                return true
            }
            return false
        }
        #expect(isCompleted, "Process \(process.stepIdentifier) should be completed")
    }

    // Print process durations
    print("\n=== Process Durations ===")
    if let grayscale = grayscaleProcess, let duration = grayscale.duration {
        print("Grayscale: \(String(format: "%.3f", duration))s")
    }
    if let blur = blurProcess, let duration = blur.duration {
        print("Blur: \(String(format: "%.3f", duration))s")
    }
    if let background = backgroundProcess, let duration = background.duration {
        print("Background: \(String(format: "%.3f", duration))s")
    }
    if let threshold = thresholdProcess, let duration = threshold.duration {
        print("Threshold: \(String(format: "%.3f", duration))s")
    }
    if let erosion = erosionProcess, let duration = erosion.duration {
        print("Erosion: \(String(format: "%.3f", duration))s")
    }
    if let dilation = dilationProcess, let duration = dilation.duration {
        print("Dilation: \(String(format: "%.3f", duration))s")
    }
    if let connectedComponents = connectedComponentsProcess, let duration = connectedComponents.duration {
        print("Connected Components: \(String(format: "%.3f", duration))s")
    }
    if let quads = quadsProcess, let duration = quads.duration {
        print("Quads: \(String(format: "%.3f", duration))s")
    }
    if let overlay = overlayProcess, let duration = overlay.duration {
        print("Overlay: \(String(format: "%.3f", duration))s")
    }

    // Save annotated frame to JPEG in temp folder
    if let frame = annotatedFrame, let texture = frame.texture {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputURL = tempDir.appendingPathComponent("star_detection_overlay_\(timestamp).jpg")

        do {
            try TextureToJPEG.save(
                texture: texture,
                to: outputURL,
                device: device,
                commandQueue: commandQueue,
                quality: 0.9
            )
            print("\n✓ Saved annotated frame to: \(outputURL.path)")
            #expect(FileManager.default.fileExists(atPath: outputURL.path), "JPEG file should exist")
        } catch {
            Issue.record("Failed to save JPEG: \(error.localizedDescription)")
        }
    }
    print("✓ Pipeline execution completed successfully")
}
