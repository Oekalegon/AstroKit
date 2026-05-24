import Testing
import Foundation
@testable import AstrophotoKit

// MARK: - Pipeline Configuration Loading Tests

/// Helper to find the main package bundle (not the test bundle)
func findMainPackageBundle() -> Bundle? {
    // Try to find bundle by looking for a class in the main module
    if let fitsFileClass = NSClassFromString("AstrophotoKit.FITSFile") {
        let bundle = Bundle(for: fitsFileClass)
        // Verify it's not the test bundle
        if !bundle.bundlePath.contains("Tests") && !bundle.bundlePath.contains("xctest") {
            return bundle
        }
    }
    
    // Try all loaded bundles to find the main package bundle (not the test bundle)
    for bundle in Bundle.allBundles {
        let bundlePath = bundle.bundlePath
        // Look for the main package bundle (contains "AstrophotoKit" but not "Tests" or "xctest")
        if bundlePath.contains("AstrophotoKit") && 
           !bundlePath.contains("Tests") && 
           !bundlePath.contains("xctest") &&
           bundlePath.contains(".bundle") {
            // Verify the resource exists in this bundle
            if bundle.url(forResource: "star-detection", withExtension: "yaml") != nil {
                return bundle
            }
        }
    }
    
    // Last resort: try to find it by searching the build directory
    let buildPath = "/Users/donwillems/Personal/Development/AstrophotoKit/.build/arm64-apple-macosx/debug/AstrophotoKit_AstrophotoKit.bundle"
    if FileManager.default.fileExists(atPath: buildPath) {
        return Bundle(path: buildPath)
    }
    
    return nil
}

/// Helper to get the pipeline resource URL from the main package bundle
func getPipelineResourceURL(name: String) throws -> URL {
    guard let mainBundle = findMainPackageBundle() else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find main package bundle"])
    }
    
    // Try without subdirectory first (resources may be flattened)
    if let url = mainBundle.url(forResource: name, withExtension: "yaml") {
        return url
    }
    
    // Try with subdirectory
    if let url = mainBundle.url(forResource: name, withExtension: "yaml", subdirectory: "Pipelines") {
        return url
    }
    
    // Try to find it by searching the resource path directly
    if let resourcePath = mainBundle.resourcePath {
        // Try root of resources first
        let rootPath = (resourcePath as NSString).appendingPathComponent("\(name).yaml")
        if FileManager.default.fileExists(atPath: rootPath) {
            return URL(fileURLWithPath: rootPath)
        }
        // Try Pipelines subdirectory
        let pipelinesPath = (resourcePath as NSString).appendingPathComponent("Pipelines")
        let filePath = (pipelinesPath as NSString).appendingPathComponent("\(name).yaml")
        if FileManager.default.fileExists(atPath: filePath) {
            return URL(fileURLWithPath: filePath)
        }
    }
    
    throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pipeline resource '\(name).yaml' not found in main package bundle at \(mainBundle.resourcePath ?? "unknown path")"])
}

@Test("Can load pipeline from resource bundle")
func loadPipelineFromResource() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    #expect(pipeline.id == "star_detection")
    #expect(pipeline.name == "Star Detection Pipeline")
    #expect(pipeline.description != nil)
    #expect(!pipeline.steps.isEmpty)
}

@Test("Pipeline has correct number of steps")
func pipelineStepCount() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // The star-detection pipeline should have 10 steps
    #expect(pipeline.steps.count == 10)
}

@Test("Pipeline steps have required fields")
func pipelineStepsHaveRequiredFields() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    for step in pipeline.steps {
        #expect(!step.id.isEmpty)
        #expect(!step.type.isEmpty)
    }
}

@Test("First step is grayscale with correct configuration")
func firstStepIsGrayscale() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    #expect(pipeline.steps.count > 0)
    let firstStep = pipeline.steps[0]
    
    #expect(firstStep.id == "grayscale")
    #expect(firstStep.type == "grayscale")
    #expect(firstStep.name == "Grayscale")
    #expect(firstStep.dataInputs.count == 1)
    #expect(firstStep.dataInputs[0].name == "input_frame")
    #expect(firstStep.dataInputs[0].from == "input_frame")
    #expect(firstStep.parameters.isEmpty)
    #expect(firstStep.outputs.count == 1)
    #expect(firstStep.outputs[0].name == "grayscale_frame")
}

@Test("Step with parameters loads correctly")
func stepWithParameters() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the blur step
    guard let blurStep = pipeline.steps.first(where: { $0.id == "blur" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Blur step not found"])
    }
    
    #expect(blurStep.type == "gaussian_blur")
    #expect(blurStep.parameters.count == 1)
    #expect(blurStep.parameters[0].name == "radius")
    #expect(blurStep.parameters[0].from == "blur_radius")
    #expect(blurStep.parameters[0].defaultValue != nil)
    
    // Check that default value is a double
    if case .double(let value) = blurStep.parameters[0].defaultValue! {
        #expect(value == 3.0)
    } else {
        Issue.record("Expected double default value for radius parameter")
    }
}

@Test("Step with multiple outputs loads correctly")
func stepWithMultipleOutputs() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the background step which has multiple outputs
    guard let backgroundStep = pipeline.steps.first(where: { $0.id == "background" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Background step not found"])
    }
    
    #expect(backgroundStep.outputs.count == 3)
    
    let outputNames = backgroundStep.outputs.map { $0.name }
    #expect(outputNames.contains("background_frame"))
    #expect(outputNames.contains("background_subtracted_frame"))
    #expect(outputNames.contains("background_level"))
}

@Test("Step with metadata restrictions loads correctly")
func stepWithMetadataRestrictions() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the grayscale step which has metadata restrictions
    guard let grayscaleStep = pipeline.steps.first(where: { $0.id == "grayscale" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Grayscale step not found"])
    }
    
    let dataInput = grayscaleStep.dataInputs[0]
    #expect(dataInput.metadataRestrictions != nil)
    
    if let restrictions = dataInput.metadataRestrictions {
        #expect(restrictions["frame_type"] != nil)
        
        if case .allowedValues(let values) = restrictions["frame_type"]! {
            #expect(values.contains("light"))
        } else {
            Issue.record("Expected allowedValues restriction for frame_type")
        }
    }
}

@Test("Step with range metadata restriction loads correctly")
func stepWithRangeMetadataRestriction() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the overlay step which has range restrictions
    guard let overlayStep = pipeline.steps.first(where: { $0.id == "overlay" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Overlay step not found"])
    }
    
    let dataInput = overlayStep.dataInputs[0]
    #expect(dataInput.metadataRestrictions != nil)
    
    if let restrictions = dataInput.metadataRestrictions {
        #expect(restrictions["exposure_time"] != nil)
        
        if case .range(let min, let max) = restrictions["exposure_time"]! {
            #expect(min == 60.0)
            #expect(max == 600.0)
        } else {
            Issue.record("Expected range restriction for exposure_time")
        }
    }
}

@Test("Step data input from previous step loads correctly")
func stepDataInputFromPreviousStep() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the blur step which takes input from grayscale step
    guard let blurStep = pipeline.steps.first(where: { $0.id == "blur" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Blur step not found"])
    }
    
    let dataInput = blurStep.dataInputs[0]
    #expect(dataInput.from == "grayscale.grayscale_frame")
}

@Test("Step parameter with int default value loads correctly")
func stepParameterWithIntDefaultValue() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the erosion step which has an int default value
    guard let erosionStep = pipeline.steps.first(where: { $0.id == "erosion" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Erosion step not found"])
    }
    
    guard let kernelSizeParam = erosionStep.parameters.first(where: { $0.name == "kernel_size" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "kernel_size parameter not found"])
    }
    
    #expect(kernelSizeParam.defaultValue != nil)
    
    if case .int(let value) = kernelSizeParam.defaultValue! {
        #expect(value == 3)
    } else {
        Issue.record("Expected int default value for kernel_size parameter")
    }
}

@Test("Step parameter with string default value loads correctly")
func stepParameterWithStringDefaultValue() throws {
    let pipelineURL = try getPipelineResourceURL(name: "star-detection")
    
    let pipeline = try Pipeline.load(from: pipelineURL)
    
    // Find the threshold step which has a string default value
    guard let thresholdStep = pipeline.steps.first(where: { $0.id == "threshold" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Threshold step not found"])
    }
    
    guard let methodParam = thresholdStep.parameters.first(where: { $0.name == "method" }) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "method parameter not found"])
    }
    
    #expect(methodParam.defaultValue != nil)
    
    if case .string(let value) = methodParam.defaultValue! {
        #expect(value == "sigma")
    } else {
        Issue.record("Expected string default value for method parameter")
    }
}

@Test("Can load pipeline from YAML string")
func loadPipelineFromString() throws {
    let yamlString = """
    id: test_pipeline
    name: Test Pipeline
    description: A test pipeline
    steps:
      - id: step1
        type: test_type
        name: Test Step
        dataInputs: []
        parameters: []
        outputs:
          - name: output1
            type: frame
            description: Test output
    """
    
    let pipeline = try Pipeline.load(from: yamlString)
    
    #expect(pipeline.id == "test_pipeline")
    #expect(pipeline.name == "Test Pipeline")
    #expect(pipeline.steps.count == 1)
    #expect(pipeline.steps[0].id == "step1")
    #expect(pipeline.steps[0].type == "test_type")
}

@Test("Invalid YAML throws error")
func invalidYAMLThrowsError() {
    let invalidYAML = """
    id: test
    name: Test
    steps: [invalid
    """
    
    #expect(throws: PipelineConfigurationError.self) {
        try Pipeline.load(from: invalidYAML)
    }
}

@Test("Missing required field throws error")
func missingRequiredFieldThrowsError() {
    let invalidYAML = """
    name: Test Pipeline
    steps: []
    """
    
    #expect(throws: PipelineConfigurationError.self) {
        try Pipeline.load(from: invalidYAML)
    }
}

