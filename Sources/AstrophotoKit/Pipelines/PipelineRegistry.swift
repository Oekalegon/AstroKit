import Foundation
import os

/// Registry for managing pipeline configurations
/// Automatically discovers and loads all pipeline YAML files from the Resources/Pipelines directory
/// Users can also add additional pipelines programmatically
public class PipelineRegistry {
    /// Shared singleton instance
    public static let shared = PipelineRegistry()

    /// Dictionary of registered pipelines, keyed by pipeline ID
    private var pipelines: [String: Pipeline] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Private initializer for singleton pattern
    private init() {
        loadBuiltInPipelines()
    }

    /// Automatically discover and load all pipeline YAML files from Resources/Pipelines
    private func loadBuiltInPipelines() {
        guard let bundle = findPackageBundle() else {
            Logger.pipeline.warning("Could not find package bundle to load built-in pipelines")
            return
        }

        // Try to find pipelines in the Pipelines subdirectory
        if let pipelinesURL = bundle.url(forResource: nil, withExtension: nil, subdirectory: "Pipelines") {
            loadPipelinesFromDirectory(url: pipelinesURL)
        } else if let resourcePath = bundle.resourcePath {
            // Fallback: try to find Pipelines directory in resource path
            let pipelinesPath = (resourcePath as NSString).appendingPathComponent("Pipelines")
            if FileManager.default.fileExists(atPath: pipelinesPath) {
                loadPipelinesFromDirectory(url: URL(fileURLWithPath: pipelinesPath))
            } else {
                // Try root of resources (in case pipelines are flattened)
                loadPipelinesFromDirectory(url: URL(fileURLWithPath: resourcePath))
            }
        }
    }

    /// Load all YAML files from a directory
    private func loadPipelinesFromDirectory(url: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in files where fileURL.pathExtension.lowercased() == "yaml" {
            do {
                let pipeline = try Pipeline.load(from: fileURL)
                register(pipeline: pipeline)
            } catch {
                Logger.pipeline.warning("Failed to load pipeline from \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Register a pipeline (thread-safe)
    /// - Parameter pipeline: The pipeline to register
    public func register(pipeline: Pipeline) {
        lock.lock()
        defer { lock.unlock() }
        pipelines[pipeline.id] = pipeline
    }

    /// Get a pipeline by ID (thread-safe)
    /// - Parameter id: The pipeline ID
    /// - Returns: The pipeline if found, nil otherwise
    public func get(id: String) -> Pipeline? {
        lock.lock()
        defer { lock.unlock() }
        return pipelines[id]
    }

    /// Get all registered pipeline IDs (thread-safe)
    /// - Returns: Array of all registered pipeline IDs
    public func getAllIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pipelines.keys).sorted()
    }

    /// Get all registered pipelines (thread-safe)
    /// - Returns: Dictionary of all registered pipelines
    public func getAll() -> [String: Pipeline] {
        lock.lock()
        defer { lock.unlock() }
        return pipelines
    }

    /// Remove a pipeline by ID (thread-safe)
    /// - Parameter id: The pipeline ID to remove
    /// - Returns: The removed pipeline if it existed, nil otherwise
    @discardableResult
    public func remove(id: String) -> Pipeline? {
        lock.lock()
        defer { lock.unlock() }
        return pipelines.removeValue(forKey: id)
    }

    /// Check if a pipeline is registered (thread-safe)
    /// - Parameter id: The pipeline ID
    /// - Returns: True if the pipeline is registered, false otherwise
    public func contains(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pipelines[id] != nil
    }

    /// Clear all registered pipelines (thread-safe)
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        pipelines.removeAll()
    }

    /// Reload built-in pipelines from Resources/Pipelines directory
    /// This will reload all YAML files but won't remove manually registered pipelines
    public func reloadBuiltInPipelines() {
        lock.lock()
        defer { lock.unlock() }

        // Store manually added pipelines (those not from built-in resources)
        // We'll identify them by checking if they're in the built-in directory
        // For simplicity, we'll just reload all and let users re-register custom ones
        let customPipelines = pipelines

        // Clear and reload
        pipelines.removeAll()
        lock.unlock()

        loadBuiltInPipelines()

        // Re-add custom pipelines that weren't in built-in resources
        lock.lock()
        for (id, pipeline) in customPipelines {
            // Only keep if it wasn't reloaded (simple heuristic: if it's not there, it was custom)
            if pipelines[id] == nil {
                pipelines[id] = pipeline
            }
        }
    }

    /// Finds the bundle containing the AstrophotoKit package
    private func findPackageBundle() -> Bundle? {
        // Method 1: Try Bundle.module (available in Swift packages with resources)
        #if canImport(Foundation)
        if let moduleBundle = Bundle.module as Bundle? {
            return moduleBundle
        }
        #endif

        // Method 2: Try to find bundle by looking for a class in our module
        if let fitsFileClass = NSClassFromString("AstrophotoKit.FITSFile") {
            return Bundle(for: fitsFileClass)
        }

        // Method 3: Try all loaded bundles to find the one containing AstrophotoKit
        for bundle in Bundle.allBundles {
            let bundlePath = bundle.bundlePath
            if bundlePath.contains("AstrophotoKit") &&
               !bundlePath.contains("Tests") &&
               !bundlePath.contains("xctest") {
                return bundle
            }
        }

        return nil
    }
}

