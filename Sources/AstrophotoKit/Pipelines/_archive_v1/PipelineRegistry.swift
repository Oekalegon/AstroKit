import Foundation

/// Registry of available pipelines
public class PipelineRegistry {
    private var pipelines: [String: Pipeline] = [:]
    
    public static let shared = PipelineRegistry()
    
    private init() {
        // Register default pipelines
        registerDefaultPipelines()
    }
    
    /// Register a pipeline
    /// - Parameter pipeline: The pipeline to register
    public func register(_ pipeline: Pipeline) {
        pipelines[pipeline.id] = pipeline
    }
    
    /// Get a pipeline by ID
    /// - Parameter id: The pipeline ID
    /// - Returns: The pipeline, or nil if not found
    public func get(_ id: String) -> Pipeline? {
        return pipelines[id]
    }
    
    /// Get all registered pipelines
    /// - Returns: Array of all registered pipelines
    public func getAll() -> [Pipeline] {
        return Array(pipelines.values)
    }
    
    /// Register default pipelines
    private func registerDefaultPipelines() {
        let starDetection = StarDetectionPipeline()
        register(starDetection)
    }
}

