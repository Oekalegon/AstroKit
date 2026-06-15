import Testing
import Foundation
@testable import AstrophotoKit

// MARK: - Pipeline Registry Tests

@Test("PipelineRegistry automatically loads built-in pipelines")
func pipelineRegistryLoadsBuiltInPipelines() throws {
    let registry = PipelineRegistry.shared

    // Should have at least the star-detection pipeline
    #expect(registry.contains(id: "star_detection"))

    // Should be able to get the pipeline
    let pipeline = registry.get(id: "star_detection")
    #expect(pipeline != nil)
    #expect(pipeline?.id == "star_detection")
    #expect(pipeline?.name == "Star Detection Pipeline")
}

@Test("PipelineRegistry allows adding custom pipelines")
func pipelineRegistryAllowsCustomPipelines() throws {
    let registry = PipelineRegistry.shared

    // Create a custom pipeline
    let customPipeline = Pipeline(
        id: "test_custom_pipeline",
        name: "Test Custom Pipeline",
        description: "A test pipeline",
        steps: []
    )

    // Register it
    registry.register(pipeline: customPipeline)

    // Should be able to retrieve it
    #expect(registry.contains(id: "test_custom_pipeline"))
    let retrieved = registry.get(id: "test_custom_pipeline")
    #expect(retrieved?.id == "test_custom_pipeline")

    // Clean up
    registry.remove(id: "test_custom_pipeline")
    #expect(!registry.contains(id: "test_custom_pipeline"))
}

@Test("PipelineRegistry provides all pipeline IDs")
func pipelineRegistryProvidesAllIDs() throws {
    let registry = PipelineRegistry.shared

    let allIDs = registry.getAllIDs()

    // Should have at least star_detection
    #expect(allIDs.contains("star_detection"))

    // IDs should be sorted
    let sorted = allIDs.sorted()
    #expect(allIDs == sorted)
}

@Test("PipelineRegistry can remove pipelines")
func pipelineRegistryCanRemovePipelines() throws {
    let registry = PipelineRegistry.shared

    // Create and register a test pipeline
    let testPipeline = Pipeline(
        id: "test_removal",
        name: "Test Removal",
        steps: []
    )

    registry.register(pipeline: testPipeline)
    #expect(registry.contains(id: "test_removal"))

    // Remove it
    let removed = registry.remove(id: "test_removal")
    #expect(removed != nil)
    #expect(removed?.id == "test_removal")
    #expect(!registry.contains(id: "test_removal"))
}

