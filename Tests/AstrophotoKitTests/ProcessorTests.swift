import Testing
import Foundation
import Metal
@testable import AstrophotoKit

@Test("Grayscale, Gaussian blur, background estimation, threshold, erosion, and dilation processors work with FITS input")
func testGrayscaleBlurBackgroundThresholdErosionAndDilationProcessors() async throws {
    // Get Metal device
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal device not available")
        return
    }

    guard let commandQueue = device.makeCommandQueue() else {
        Issue.record("Could not create Metal command queue")
        return
    }

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
        for b in Bundle.allBundles {
            if let url = b.url(forResource: fitsFileName, withExtension: "fits") {
                resourceURL = url
                break
            }
        }
    }
    guard let resourceURL = resourceURL else { return }

    // Open FITS file and read image
    let fitsFile = try FITSFile(path: resourceURL.path)
    let fitsImage = try fitsFile.readFITSImage()

    // Create Frame from FITS image
    let inputFrame = try Frame(fitsImage: fitsImage, device: device)

    // Verify input frame has texture
    #expect(inputFrame.texture != nil, "Input frame should have a texture")
    let inputTexture = inputFrame.texture!
    print("Input frame: \(inputTexture.width)x\(inputTexture.height), format: \(inputTexture.pixelFormat)")

    // Test 1: Grayscale processor
    let grayscaleProcessor = GrayscaleProcessor()
    let grayscaleInputs: [String: ProcessData] = ["input_frame": inputFrame]
    var grayscaleOutputs: [String: ProcessData] = ["grayscale_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)]
    try grayscaleProcessor.execute(
        inputs: grayscaleInputs,
        outputs: &grayscaleOutputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    // Verify grayscale output
    guard let grayscaleFrame = grayscaleOutputs["grayscale_frame"] as? Frame else {
        Issue.record("Grayscale processor did not return grayscale_frame")
        return
    }

    #expect(grayscaleFrame.texture != nil, "Grayscale frame should have a texture")
    #expect(grayscaleFrame.colorSpace == ColorSpace.greyscale, "Grayscale frame should have greyscale color space")
    let grayscaleTexture = grayscaleFrame.texture!
    #expect(grayscaleTexture.width == inputTexture.width, "Grayscale output should have same width as input")
    #expect(grayscaleTexture.height == inputTexture.height, "Grayscale output should have same height as input")
    print(
        "Grayscale output: \(grayscaleTexture.width)x\(grayscaleTexture.height), " +
        "format: \(grayscaleTexture.pixelFormat)"
    )

    // Test 2: Gaussian blur processor (using grayscale output as input)
    let blurProcessor = GaussianBlurProcessor()
    let blurInputs: [String: ProcessData] = ["input_frame": grayscaleFrame]
    let blurParameters: [String: Parameter] = [
        "radius": Parameter.double(3.0)
    ]
    var blurOutputs: [String: ProcessData] = ["blurred_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)]
    try blurProcessor.execute(
        inputs: blurInputs,
        outputs: &blurOutputs,
        parameters: blurParameters,
        device: device,
        commandQueue: commandQueue
    )

    // Verify blur output
    guard let blurredFrame = blurOutputs["blurred_frame"] as? Frame else {
        Issue.record("Blur processor did not return blurred_frame")
        return
    }

    #expect(blurredFrame.texture != nil, "Blurred frame should have a texture")
    let blurredTexture = blurredFrame.texture!
    #expect(blurredTexture.width == inputTexture.width, "Blurred output should have same width as input")
    #expect(blurredTexture.height == inputTexture.height, "Blurred output should have same height as input")
    print(
        "Blur output: \(blurredTexture.width)x\(blurredTexture.height), format: \(blurredTexture.pixelFormat)"
    )

    // Test 3: Background estimation processor (using blurred output as input)
    let backgroundProcessor = BackgroundEstimationProcessor()
    let backgroundInputs: [String: ProcessData] = ["input_frame": blurredFrame]
    var backgroundOutputs: [String: ProcessData] = [
        "background_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float),
        "background_subtracted_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float),
        "background_level": TableData()
    ]
    try backgroundProcessor.execute(
        inputs: backgroundInputs,
        outputs: &backgroundOutputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    // Verify background outputs
    guard let backgroundFrame = backgroundOutputs["background_frame"] as? Frame else {
        Issue.record("Background processor did not return background_frame")
        return
    }
    #expect(backgroundFrame.texture != nil, "Background frame should have a texture")
    let backgroundTexture = backgroundFrame.texture!
    #expect(backgroundTexture.width == inputTexture.width, "Background output should have same width as input")
    #expect(backgroundTexture.height == inputTexture.height, "Background output should have same height as input")
    print("Background frame: \(backgroundTexture.width)x\(backgroundTexture.height), format: \(backgroundTexture.pixelFormat)")

    guard let subtractedFrame = backgroundOutputs["background_subtracted_frame"] as? Frame else {
        Issue.record("Background processor did not return background_subtracted_frame")
        return
    }
    #expect(subtractedFrame.texture != nil, "Background-subtracted frame should have a texture")
    let subtractedTexture = subtractedFrame.texture!
    #expect(subtractedTexture.width == inputTexture.width, "Background-subtracted output should have same width as input")
    #expect(subtractedTexture.height == inputTexture.height, "Background-subtracted output should have same height as input")
    print("Background-subtracted frame: \(subtractedTexture.width)x\(subtractedTexture.height), format: \(subtractedTexture.pixelFormat)")

    guard let backgroundLevelTable = backgroundOutputs["background_level"] as? TableData else {
        Issue.record("Background processor did not return background_level")
        return
    }
    #expect(backgroundLevelTable.isInstantiated, "Background level table should be instantiated")
    #expect(backgroundLevelTable.dataFrame != nil, "Background level table should have DataFrame")
    #expect(backgroundLevelTable.rowCount == 1, "Background level table should have 1 row")
    #expect(backgroundLevelTable.columnCount >= 1, "Background level table should have at least 1 column")
    print("Background level table: \(backgroundLevelTable.rowCount) row(s), \(backgroundLevelTable.columnCount) column(s)")

    // Test 4: Threshold processor (using background-subtracted output as input)
    let thresholdProcessor = ThresholdProcessor()
    let thresholdInputs: [String: ProcessData] = ["input_frame": subtractedFrame]
    let thresholdParameters: [String: Parameter] = [
        "threshold_value": Parameter.double(3.0),
        "method": Parameter.string("sigma")
    ]
    var thresholdOutputs: [String: ProcessData] = [
        "thresholded_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)
    ]
    try thresholdProcessor.execute(
        inputs: thresholdInputs,
        outputs: &thresholdOutputs,
        parameters: thresholdParameters,
        device: device,
        commandQueue: commandQueue
    )

    // Verify threshold output
    guard let thresholdedFrame = thresholdOutputs["thresholded_frame"] as? Frame else {
        Issue.record("Threshold processor did not return thresholded_frame")
        return
    }
    #expect(thresholdedFrame.texture != nil, "Thresholded frame should have a texture")
    let thresholdedTexture = thresholdedFrame.texture!
    #expect(thresholdedTexture.width == inputTexture.width, "Thresholded output should have same width as input")
    #expect(thresholdedTexture.height == inputTexture.height, "Thresholded output should have same height as input")
    print("Thresholded frame: \(thresholdedTexture.width)x\(thresholdedTexture.height), format: \(thresholdedTexture.pixelFormat)")

    // Test 5: Erosion processor (using thresholded output as input)
    let erosionProcessor = ErosionProcessor()
    let erosionInputs: [String: ProcessData] = ["input_frame": thresholdedFrame]
    let erosionParameters: [String: Parameter] = [
        "kernel_size": Parameter.int(3)
    ]
    var erosionOutputs: [String: ProcessData] = [
        "eroded_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)
    ]
    try erosionProcessor.execute(
        inputs: erosionInputs,
        outputs: &erosionOutputs,
        parameters: erosionParameters,
        device: device,
        commandQueue: commandQueue
    )

    // Verify erosion output
    guard let erodedFrame = erosionOutputs["eroded_frame"] as? Frame else {
        Issue.record("Erosion processor did not return eroded_frame")
        return
    }
    #expect(erodedFrame.texture != nil, "Eroded frame should have a texture")
    let erodedTexture = erodedFrame.texture!
    #expect(erodedTexture.width == inputTexture.width, "Eroded output should have same width as input")
    #expect(erodedTexture.height == inputTexture.height, "Eroded output should have same height as input")
    print("Eroded frame: \(erodedTexture.width)x\(erodedTexture.height), format: \(erodedTexture.pixelFormat)")

    // Test 6: Dilation processor (using eroded output as input)
    let dilationProcessor = DilationProcessor()
    let dilationInputs: [String: ProcessData] = ["input_frame": erodedFrame]
    let dilationParameters: [String: Parameter] = [
        "kernel_size": Parameter.int(3)
    ]
    var dilationOutputs: [String: ProcessData] = [
        "dilated_frame": Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)
    ]
    try dilationProcessor.execute(
        inputs: dilationInputs,
        outputs: &dilationOutputs,
        parameters: dilationParameters,
        device: device,
        commandQueue: commandQueue
    )

    // Verify dilation output
    guard let dilatedFrame = dilationOutputs["dilated_frame"] as? Frame else {
        Issue.record("Dilation processor did not return dilated_frame")
        return
    }
    #expect(dilatedFrame.texture != nil, "Dilated frame should have a texture")
    let dilatedTexture = dilatedFrame.texture!
    #expect(dilatedTexture.width == inputTexture.width, "Dilated output should have same width as input")
    #expect(dilatedTexture.height == inputTexture.height, "Dilated output should have same height as input")
    print("Dilated frame: \(dilatedTexture.width)x\(dilatedTexture.height), format: \(dilatedTexture.pixelFormat)")

    // Test 7: Run all six processors in sequence (simulating pipeline)
    print("Successfully tested grayscale, blur, background estimation, threshold, erosion, and dilation processors in sequence")
}
