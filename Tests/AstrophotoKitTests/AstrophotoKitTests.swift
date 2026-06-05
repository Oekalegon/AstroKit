import Testing
@testable import AstrophotoKit
import Metal

// MARK: - Helper Functions

/// Helper function to get the path to a test resource
/// - Parameters:
///   - name: The name of the resource file (without extension)
///   - ext: The file extension (e.g., "fits")
/// - Returns: The file path to the resource
func pathForTestResource(name: String, ext: String) throws -> String {
    guard let resourceURL = Bundle.module.url(forResource: name, withExtension: ext) else {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test resource '\(name).\(ext)' not found"])
    }
    return resourceURL.path
}

/// Helper to get all FITS files in the test resources
func getAllFITSFiles() -> [String] {
    guard let resourcePath = Bundle.module.resourcePath else {
        return []
    }
    let resourceURL = URL(fileURLWithPath: resourcePath)
    
    guard let files = try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil) else {
        return []
    }
    
    return files
        .filter { $0.pathExtension.lowercased() == "fits" }
        .map { $0.path }
}

// MARK: - Basic Tests

@Test("AstrophotoKit can be initialized")
func astrophotoKitInitialization() {
    // This test verifies that AstrophotoKit can be initialized without errors
    // The fact that this compiles and runs successfully is the test
    _ = AstrophotoKit()
}

@Test("Can open a FITS file")
func openFITSFile() throws {
    let files = getAllFITSFiles()
    guard !files.isEmpty else { return }
    
    let filePath = files[0]
    let fitsFile = try FITSFile(path: filePath)
    // Verify we can read HDUs from the opened file
    let numHDUs = try fitsFile.numberOfHDUs()
    #expect(numHDUs > 0)
}

@Test("Can read number of HDUs from FITS file")
func numberOfHDUs() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let numHDUs = try fitsFile.numberOfHDUs()
    #expect(numHDUs >= 1, "FITS file should have at least one HDU")
}

// MARK: - Metadata Tests

@Test("Can read FITS header metadata")
func readFITSHeader() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let metadata = try fitsFile.readHeader()
    
    #expect(!metadata.isEmpty, "FITS file should have header metadata")
    
    // Check for common FITS keywords
    #expect(metadata["NAXIS"] != nil, "Should have NAXIS keyword")
    #expect(metadata["BITPIX"] != nil, "Should have BITPIX keyword")
}

@Test("Can read image metadata from FITS file")
func readImageMetadata() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let image = try fitsFile.readFITSImage()
    
    // Check image dimensions
    #expect(image.width > 0, "Image should have positive width")
    #expect(image.height > 0, "Image should have positive height")
    
    // Check metadata exists
    #expect(!image.metadata.isEmpty, "Image should have metadata")
    
    // Check for common astronomical keywords
    if let naxis1 = image.metadata["NAXIS1"]?.intValue {
        #expect(Int(naxis1) == image.width, "NAXIS1 should match image width")
    }
    
    if let naxis2 = image.metadata["NAXIS2"]?.intValue {
        #expect(Int(naxis2) == image.height, "NAXIS2 should match image height")
    }
}

// MARK: - Image Data Tests

@Test("Can read image pixel data from FITS file")
func readImageData() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let image = try fitsFile.readFITSImage()
    
    // Check pixel data
    #expect(!image.pixelData.isEmpty, "Image should have pixel data")
    #expect(image.pixelData.count == image.width * image.height, "Pixel data count should match image dimensions")
    
    // Check that pixel values are normalized (0-1 range)
    let minValue = image.pixelData.min() ?? 0
    let maxValue = image.pixelData.max() ?? 0
    #expect(minValue >= 0, "Pixel values should be >= 0")
    #expect(maxValue <= 1.0, "Pixel values should be <= 1.0 (normalized)")
}

@Test("Image data type is valid")
func imageDataType() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let image = try fitsFile.readFITSImage()
    
    // Check data type is valid (FITSDataType is an enum, always has a value)
    // Just verify bitpix is set, which implies dataType is valid
    
    // Check bitpix is set
    #expect(image.bitpix != 0, "BITPIX should be non-zero")
}

// MARK: - Multiple Files Tests

@Test("Can read all FITS test files")
func readAllFITSFiles() throws {
    let files = getAllFITSFiles()
    guard !files.isEmpty else { return }
    
    for filePath in files {
        let fitsFile = try FITSFile(path: filePath)
        let image = try fitsFile.readFITSImage()
        
        #expect(image.width > 0, "File \(filePath) should have valid width")
        #expect(image.height > 0, "File \(filePath) should have valid height")
        #expect(!image.pixelData.isEmpty, "File \(filePath) should have pixel data")
    }
}

@Test("Compare image dimensions across multiple files")
func compareImageDimensions() throws {
    let files = getAllFITSFiles()
    guard files.count >= 2 else {
        // Skip if not enough files
        return
    }
    
    var dimensions: [(width: Int, height: Int)] = []
    
    for filePath in files.prefix(5) { // Test first 5 files
        let fitsFile = try FITSFile(path: filePath)
        let image = try fitsFile.readFITSImage()
        dimensions.append((image.width, image.height))
    }
    
    // Check if all images have the same dimensions (common for calibrated images)
    if dimensions.count > 1 {
        let firstDim = dimensions[0]
        let allSame = dimensions.allSatisfy { $0.width == firstDim.width && $0.height == firstDim.height }
        
        if allSame {
            print("All test images have consistent dimensions: \(firstDim.width)x\(firstDim.height)")
        } else {
            print("Test images have varying dimensions")
        }
    }
}

// MARK: - Metal Integration Tests

@Test("Can create Metal texture from FITS image")
func createMetalTexture() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        // Skip if Metal not available
        return
    }
    
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let image = try fitsFile.readFITSImage()
    
    let texture = try image.createMetalTexture(device: device)
    #expect(texture.width == image.width, "Texture width should match image width")
    #expect(texture.height == image.height, "Texture height should match image height")
    #expect(texture.pixelFormat == .r32Float, "Texture should use r32Float format")
}

@Test("Can create Metal buffer from FITS image")
func createMetalBuffer() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        // Skip if Metal not available
        return
    }
    
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let image = try fitsFile.readFITSImage()
    
    let buffer = image.createMetalBuffer(device: device)
    #expect(buffer != nil, "Should create Metal buffer")
    #expect(buffer?.length == image.pixelData.count * MemoryLayout<Float32>.size, "Buffer size should match pixel data size")
}

// MARK: - Astronomical Metadata Tests

@Test("FITS file contains astronomical keywords")
func astronomicalKeywords() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    let fitsFile = try FITSFile(path: firstFile)
    let image = try fitsFile.readFITSImage()
    
    // Check for common astronomical keywords (may or may not be present)
    let commonKeywords = ["EXPTIME", "EXPOSURE", "EXPOSURE_TIME", "FILTER", "OBJECT", "RA", "DEC", "DATE-OBS"]
    
    var foundKeywords: [String] = []
    for keyword in commonKeywords {
        if image.metadata[keyword] != nil {
            foundKeywords.append(keyword)
        }
    }
    
    print("Found astronomical keywords: \(foundKeywords)")
    // Don't fail if keywords aren't present, just log what we found
}

// MARK: - Error Handling Tests

@Test("Opening non-existent file throws error")
func openNonExistentFile() throws {
    let nonExistentPath = "/path/that/does/not/exist.fits"
    
    do {
        _ = try FITSFile(path: nonExistentPath)
        Issue.record("Expected error when opening non-existent file")
    } catch let error as FITSFileError {
        // Verify it's the correct error case
        if case .cannotOpenFile = error {
            // Expected error type - test passes
        } else {
            Issue.record("Expected cannotOpenFile error, got \(error)")
        }
    } catch {
        Issue.record("Expected FITSFileError, got \(error)")
    }
}

// MARK: - Performance Tests

/// Helper function to measure execution time
func measureTime(_ block: () throws -> Void) rethrows -> TimeInterval {
    let start = Date()
    try block()
    return Date().timeIntervalSince(start)
}

/// Helper function to measure execution time of async operations
func measureTimeAsync(_ block: () async throws -> Void) async rethrows -> TimeInterval {
    let start = Date()
    try await block()
    return Date().timeIntervalSince(start)
}

@Test("Performance: Reading FITS file and image data")
func readPerformance() throws {
    let files = getAllFITSFiles()
    guard let firstFile = files.first else {
        return
    }
    
    // Warm up run
    _ = try measureTime {
        let fitsFile = try FITSFile(path: firstFile)
        _ = try fitsFile.readFITSImage()
    }
    
    // Actual performance measurement - run multiple iterations
    let iterations = 5
    var times: [TimeInterval] = []
    
    for _ in 0..<iterations {
        let time = try measureTime {
            let fitsFile = try FITSFile(path: firstFile)
            _ = try fitsFile.readFITSImage()
        }
        times.append(time)
    }
    
    // Calculate statistics
    let averageTime = times.reduce(0, +) / Double(iterations)
    let minTime = times.min() ?? 0
    let maxTime = times.max() ?? 0
    
    // Report results
    print("Performance test results for reading FITS file:")
    print("  File: \(firstFile)")
    print("  Iterations: \(iterations)")
    print("  Average time: \(String(format: "%.3f", averageTime * 1000)) ms")
    print("  Min time: \(String(format: "%.3f", minTime * 1000)) ms")
    print("  Max time: \(String(format: "%.3f", maxTime * 1000)) ms")
    
    // Basic sanity check - reading should complete in reasonable time (< 10 seconds)
    #expect(averageTime < 10.0, "FITS file reading should complete in reasonable time")
}

@Test("Performance: Reading multiple FITS files")
func readMultipleFilesPerformance() throws {
    let files = getAllFITSFiles()
    guard !files.isEmpty else {
        return
    }
    
    // Test with first 3 files
    let testFiles = Array(files.prefix(3))
    
    let totalTime = try measureTime {
        for filePath in testFiles {
            let fitsFile = try FITSFile(path: filePath)
            _ = try fitsFile.readFITSImage()
        }
    }
    
    let averageTimePerFile = totalTime / Double(testFiles.count)
    
    print("Performance test results for reading multiple FITS files:")
    print("  Files processed: \(testFiles.count)")
    print("  Total time: \(String(format: "%.3f", totalTime * 1000)) ms")
    print("  Average time per file: \(String(format: "%.3f", averageTimePerFile * 1000)) ms")
    
    // Basic sanity check
    #expect(totalTime < 30.0, "Reading multiple FITS files should complete in reasonable time")
}

