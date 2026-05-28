import Metal
import MetalKit
import os

public struct AstrophotoKit {
    public init() {
    }

    // Cache for shader libraries per device to avoid recompilation
    private static var shaderLibraryCache: [ObjectIdentifier: MTLLibrary] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.astrophotokit.shaderLibraryCache")

    /// Loads the default Metal device
    public static func makeDefaultDevice() -> MTLDevice? {
        return MTLCreateSystemDefaultDevice()
    }

    /// Creates a Metal library from the compiled shaders in this package
    /// Tries multiple methods to find the compiled Metal shaders
    /// Caches the library per device to avoid recompilation overhead
    public static func makeShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        let deviceID = ObjectIdentifier(device)
        
        // Check cache first
        return cacheQueue.sync {
            if let cachedLibrary = shaderLibraryCache[deviceID] {
                return cachedLibrary
            }
            
            // Load or compile library
            let library: MTLLibrary? = loadOrCompileShaderLibrary(device: device)
            
            // Cache it if successful
            if let library = library {
                shaderLibraryCache[deviceID] = library
            }
            
            return library
        }
    }
    
    /// Internal method to load or compile shader library
    private static func loadOrCompileShaderLibrary(device: MTLDevice) -> MTLLibrary? {
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
        // For now, only load the essential shaders to avoid duplicate definition errors
        // TODO: Fix duplicate struct definitions across shader files or use include guards
        let essentialShaders = [
            "GrayscaleShader",
            "GaussianBlurShader",
            "LocalMedianShader",
            "BackgroundSubtractionShader",
            "ThresholdShader",
            "ErosionShader",
            "DilationShader",
            "ConnectedComponentsShader",
            "StarDetectionOverlayShader",
            "WaveletDonutShader",
            "FWHMShader",
            "HFDShader",
            "HoughCircleShader",
            "WarpShader",
            "StackShader",
            "RegistrationMatchingShader"
        ]
        if let shaderSource = loadShaderSource(requiredShaders: essentialShaders) {
            Logger.swiftfitsio.debug("Attempting to compile Metal library from source...")
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                Logger.swiftfitsio.debug("Successfully compiled Metal shader library from source")
                return library
            } catch {
                Logger.swiftfitsio.error("Failed to compile Metal shader library: \(error.localizedDescription)")
                // Try to get more details about the compilation error
                if let metalError = error as NSError? {
                    Logger.swiftfitsio.error("Metal error details: \(metalError)")
                }
            }
        } else {
            Logger.swiftfitsio.error("loadShaderSource() returned nil")
        }

        return nil
    }

    /// Loads the Metal shader source code from the package bundle
    /// Combines both the normal and inverse shader files
    /// - Parameter requiredShaders: Optional list of specific shader names to load.
    ///   If nil, loads all shaders. Use this to avoid duplicate definition errors.
    private static func loadShaderSource(requiredShaders: [String]? = nil) -> String? {
        Logger.swiftfitsio.debug("Starting shader source loading...")
        var shaderSources: [String] = []
        let allShaderFiles = [
            "ImageShader", "ImageInverseShader", "HistogramShader", "GaussianBlurShader",
            "GrayscaleShader", "BackgroundSubtractionShader", "ThresholdShader",
            "LocalMedianShader", "StatisticsShader", "ErosionShader", "DilationShader",
            "ConnectedComponentsShader", "StarDetectionOverlayShader", "WaveletDonutShader",
            "FWHMShader", "HFDShader", "HoughCircleShader", "RegistrationMatchingShader"
        ]
        let shaderFiles = requiredShaders ?? allShaderFiles
        Logger.swiftfitsio.debug(
            "Looking for \(shaderFiles.count) shader files: \(shaderFiles.joined(separator: ", "))"
        )

        // Try multiple methods to find the shader files
        var bundlesToTry: [Bundle?] = [
            findPackageBundle(),
            Bundle.main,
            Bundle(for: FITSFile.self)
        ]

        // Also try Bundle.module explicitly (for test environments)
        #if canImport(Foundation)
        if let moduleBundle = Bundle.module as Bundle? {
            bundlesToTry.insert(moduleBundle, at: 0)
        }
        #endif

        // Try all bundles containing AstrophotoKit (including build bundles)
        for bundle in Bundle.allBundles {
            let bundlePath = bundle.bundlePath
            if bundlePath.contains("AstrophotoKit") && !bundlePath.contains("Tests") {
                bundlesToTry.append(bundle)
            }
        }

        for bundle in bundlesToTry.compactMap({ $0 }) {
            Logger.swiftfitsio.debug("Trying bundle at \(bundle.bundlePath)")
            Logger.swiftfitsio.debug("Bundle resource path: \(bundle.resourcePath ?? "nil")")

            for shaderName in shaderFiles {
                // Check if we already have this shader
                if shaderSources.contains(where: { $0.contains(shaderName) }) {
                    continue
                }

                // Try without subdirectory first (shaders are in bundle root after processing)
                if let shaderURL = bundle.url(forResource: shaderName, withExtension: "metal"),
                   let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) {
                    shaderSources.append(shaderSource)
                    Logger.swiftfitsio.debug("Loaded \(shaderName).metal from bundle root: \(shaderURL.path)")
                    continue
                }

                // Try with subdirectory (for source-based loading)
                if let shaderURL = bundle.url(forResource: shaderName, withExtension: "metal", subdirectory: "Shaders"),
                   let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) {
                    shaderSources.append(shaderSource)
                    Logger.swiftfitsio.debug("Loaded \(shaderName).metal from Shaders subdirectory: \(shaderURL.path)")
                    continue
                }

                // Try from resource path (check bundle root first, then Shaders subdirectory)
                if let resourcePath = bundle.resourcePath {
                    // Try bundle root first (where SPM puts processed resources)
                    let shaderPathRoot = (resourcePath as NSString).appendingPathComponent("\(shaderName).metal")
                    if FileManager.default.fileExists(atPath: shaderPathRoot),
                       let shaderSource = try? String(contentsOfFile: shaderPathRoot, encoding: .utf8) {
                        shaderSources.append(shaderSource)
                        Logger.swiftfitsio.debug("Loaded \(shaderName).metal from bundle root: \(shaderPathRoot)")
                        continue
                    }

                    // Try Shaders subdirectory
                    let shaderPath = (resourcePath as NSString).appendingPathComponent("Shaders/\(shaderName).metal")
                    if FileManager.default.fileExists(atPath: shaderPath),
                       let shaderSource = try? String(contentsOfFile: shaderPath, encoding: .utf8) {
                        shaderSources.append(shaderSource)
                        Logger.swiftfitsio.debug("Loaded \(shaderName).metal from Shaders subdirectory: \(shaderPath)")
                        continue
                    }
                }
            }

            // If we found all shaders, we're done
            if shaderSources.count >= shaderFiles.count {
                break
            }
        }

        // Fallback: Try to load from build bundle directly
        if shaderSources.isEmpty {
            Logger.swiftfitsio.debug("Trying to load shaders from build bundle")
            let fileManager = FileManager.default

            // Find package root from current file location
            let currentFileDir = (#file as NSString).deletingLastPathComponent
            Logger.swiftfitsio.debug("Current file directory: \(currentFileDir)")
            // Go up from Sources/AstrophotoKit to package root
            let sourcesDir = (currentFileDir as NSString).deletingLastPathComponent
            let packageRoot = (sourcesDir as NSString).deletingLastPathComponent
            Logger.swiftfitsio.debug("Package root: \(packageRoot)")

            // Try to find the build bundle
            let possibleBundlePaths = [
                "index-build/arm64-apple-macosx/debug/AstrophotoKit_AstrophotoKit.bundle",
                "arm64-apple-macosx/debug/AstrophotoKit_AstrophotoKit.bundle"
            ]

            for relativeBundlePath in possibleBundlePaths {
                let buildDir = (packageRoot as NSString).appendingPathComponent(".build")
                let bundlePath = (buildDir as NSString).appendingPathComponent(relativeBundlePath)
                let finalPath = (bundlePath as NSString).standardizingPath

                Logger.swiftfitsio.debug("Trying build bundle path: \(finalPath)")
                Logger.swiftfitsio.debug("Path exists: \(fileManager.fileExists(atPath: finalPath))")

                if fileManager.fileExists(atPath: finalPath) {
                    var foundInPath = 0
                    for shaderName in shaderFiles {
                        let shaderPath = (finalPath as NSString)
                            .appendingPathComponent("\(shaderName).metal")
                        if fileManager.fileExists(atPath: shaderPath),
                           let shaderSource = try? String(
                               contentsOfFile: shaderPath,
                               encoding: .utf8
                            ) {
                            shaderSources.append(shaderSource)
                            foundInPath += 1
                            Logger.swiftfitsio.debug("Loaded \(shaderName).metal from build bundle: \(shaderPath)")
                        }
                    }
                    if foundInPath > 0 {
                        Logger.swiftfitsio.debug("Found \(foundInPath) shaders in build bundle")
                        break
                    }
                }
            }
        }

        // Final fallback: Try to load from source directory (always works in development)
        // This is the most reliable method for tests and development
        if shaderSources.isEmpty {
            let fileManager = FileManager.default
            // #file gives absolute path to this Swift file
            // Go from Sources/AstrophotoKit/AstrophotoKit.swift to Sources/AstrophotoKit/Shaders
            let currentFileDir = (#file as NSString).deletingLastPathComponent
            let shadersDir = (currentFileDir as NSString).appendingPathComponent("Shaders")

            if fileManager.fileExists(atPath: shadersDir) {
                for shaderName in shaderFiles {
                    let shaderPath = (shadersDir as NSString)
                        .appendingPathComponent("\(shaderName).metal")
                    if fileManager.fileExists(atPath: shaderPath),
                       let shaderSource = try? String(
                           contentsOfFile: shaderPath,
                           encoding: .utf8
                       ) {
                        shaderSources.append(shaderSource)
                    }
                }
            }
        }

        // Combine all shader sources
        // Note: When combining multiple Metal files, we need to handle duplicate definitions
        // For now, we'll combine them with a separator and let Metal handle it
        // In the future, we might want to use #include or proper guards
        if !shaderSources.isEmpty {
            // Combine with double newline to separate files
            let combined = shaderSources.joined(separator: "\n\n// ===== Next Shader File =====\n\n")
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

