import Metal
import MetalKit
import os

/// Logger extension for FITSIO operations
extension Logger {
    /// Logger for FITSIO-related operations
    public static let swiftfitsio = Logger(subsystem: "com.astrophotokit", category: "swift-fitsio")
    
    /// Logger for pipeline-related operations
    public static let pipeline = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-pipeline")
    
    /// Logger for filter-related operations
    public static let filter = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-filter")
    
    /// Logger for computer-related operations
    public static let computers = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-computers")
    
    /// Logger for data-related operations
    public static let data = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-data")
    
    /// Logger for UI-related operations
    public static let ui = Logger(subsystem: "com.astrophotokit", category: "astrophotokit-ui")
}
public struct AstrophotoKit {
    public init() {
    }
    
    /// Loads the default Metal device
    public static func makeDefaultDevice() -> MTLDevice? {
        return MTLCreateSystemDefaultDevice()
    }
    
    /// Creates a Metal library from the compiled shaders in this package
    /// Tries multiple methods to find the compiled Metal shaders
    public static func makeShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        // Method 1: Try to load from the package bundle (for Swift packages)
        // This works when the package is used as a dependency
        if let packageBundle = findPackageBundle() {
            if let libraryURL = packageBundle.url(forResource: "default", withExtension: "metallib"),
               let library = try? device.makeLibrary(URL: libraryURL) {
                return library
            }
        }
        
        // Method 2: Try the default library (works when shaders are in the app target)
        if let defaultLibrary = device.makeDefaultLibrary() {
            // Check if our shaders are available
            if defaultLibrary.makeFunction(name: "vertex_main") != nil {
                return defaultLibrary
            }
        }
        
        // Method 3: Compile from source at runtime (fallback for Swift packages)
        // Load the shader source files from package resources and combine them
        if let shaderSource = loadShaderSource(),
           let library = try? device.makeLibrary(source: shaderSource, options: nil) {
            return library
        }
        
        return nil
    }
    
    /// Loads the Metal shader source code from the package bundle
    /// Combines both the normal and inverse shader files
    private static func loadShaderSource() -> String? {
        var shaderSources: [String] = []
        let shaderFiles = ["ImageShader", "ImageInverseShader", "HistogramShader", "GaussianBlurShader", "BackgroundSubtractionShader", "ThresholdShader", "LocalMedianShader", "StatisticsShader", "ErosionShader", "DilationShader", "ConnectedComponentsShader", "StarDetectionOverlayShader", "CrossSectionShader"]
        
        // Try multiple methods to find the shader files
        let bundlesToTry: [Bundle?] = [
            findPackageBundle(),
            Bundle.main,
            Bundle(for: FITSFile.self)
        ]
        
        for bundle in bundlesToTry.compactMap({ $0 }) {
            Logger.swiftfitsio.debug("Trying bundle at \(bundle.bundlePath)")
            
            for shaderName in shaderFiles {
                // Check if we already have this shader
                if shaderSources.contains(where: { $0.contains(shaderName) }) {
                    continue
                }
                
                // Try with subdirectory first
                if let shaderURL = bundle.url(forResource: shaderName, withExtension: "metal", subdirectory: "Shaders"),
                   let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) {
                    shaderSources.append(shaderSource)
                    Logger.swiftfitsio.debug("Loaded \(shaderName).metal from Shaders subdirectory")
                    continue
                }
                
                // Try without subdirectory
                if let shaderURL = bundle.url(forResource: shaderName, withExtension: "metal"),
                   let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) {
                    shaderSources.append(shaderSource)
                    Logger.swiftfitsio.debug("Loaded \(shaderName).metal from bundle root")
                    continue
                }
                
                // Try from resource path
                if let resourcePath = bundle.resourcePath {
                    let shaderPath = (resourcePath as NSString).appendingPathComponent("Shaders/\(shaderName).metal")
                    if FileManager.default.fileExists(atPath: shaderPath),
                       let shaderSource = try? String(contentsOfFile: shaderPath, encoding: .utf8) {
                        shaderSources.append(shaderSource)
                        Logger.swiftfitsio.debug("Loaded \(shaderName).metal from \(shaderPath)")
                        continue
                    }
                    
                    // Try without subdirectory
                    let shaderPath2 = (resourcePath as NSString).appendingPathComponent("\(shaderName).metal")
                    if FileManager.default.fileExists(atPath: shaderPath2),
                       let shaderSource = try? String(contentsOfFile: shaderPath2, encoding: .utf8) {
                        shaderSources.append(shaderSource)
                        Logger.swiftfitsio.debug("Loaded \(shaderName).metal from \(shaderPath2)")
                        continue
                    }
                }
            }
            
            // If we found all shaders, we're done
            if shaderSources.count >= shaderFiles.count {
                break
            }
        }
        
        // Combine all shader sources (Metal can compile multiple files combined)
        if !shaderSources.isEmpty {
            let combined = shaderSources.joined(separator: "\n")
            Logger.swiftfitsio.debug("Successfully loaded \(shaderSources.count) shader file(s), total size: \(combined.count) characters")
            return combined
        }
        
        Logger.swiftfitsio.notice("Failed to load any shader files from bundles")
        return nil
    }
    
    /// Finds the bundle containing the AstrophotoKit package
    private static func findPackageBundle() -> Bundle? {
        // Method 1: Try Bundle.module (available in Swift packages with resources)
        #if canImport(Foundation)
        // Bundle.module is available when resources are included in Package.swift
        // This is the preferred method for Swift packages
        if let moduleBundle = Bundle.module as Bundle? {
            Logger.swiftfitsio.debug("Found bundle via Bundle.module at \(moduleBundle.bundlePath)")
            Logger.swiftfitsio.debug("Bundle resource path: \(moduleBundle.resourcePath ?? "nil")")
            return moduleBundle
        }
        #endif
        
        // Method 2: Try to find bundle by looking for a class in our module
        // Use FITSFile class which is in this package
        if let fitsFileClass = NSClassFromString("AstrophotoKit.FITSFile") {
            let bundle = Bundle(for: fitsFileClass)
            Logger.swiftfitsio.debug("Found bundle via FITSFile class at \(bundle.bundlePath)")
            Logger.swiftfitsio.debug("Bundle resource path: \(bundle.resourcePath ?? "nil")")
            return bundle
        }
        
        // Method 3: Try all loaded bundles to find the one containing AstrophotoKit
        for bundle in Bundle.allBundles {
            let bundlePath = bundle.bundlePath
            // Check if this bundle is related to AstrophotoKit
            if bundlePath.contains("AstrophotoKit") ||
               bundle.bundleIdentifier?.contains("AstrophotoKit") == true {
                Logger.swiftfitsio.debug("Found bundle in allBundles at \(bundlePath)")
                Logger.swiftfitsio.debug("Bundle resource path: \(bundle.resourcePath ?? "nil")")
                return bundle
            }
        }
        
        Logger.swiftfitsio.notice("Could not find package bundle in \(Bundle.allBundles.count) loaded bundles")
        return nil
    }
}

