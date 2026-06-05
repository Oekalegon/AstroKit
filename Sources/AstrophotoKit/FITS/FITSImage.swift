import Foundation
import Metal
import MetalKit
import Accelerate
import CCFITSIO
import os

/// Shared utility for converting screen coordinates to image pixel coordinates
public enum FITSCoordinateConverter {
    /// Converts normalized screen coordinates to texture coordinates
    /// - Parameters:
    ///   - normalizedX: Normalized X coordinate (-1 to 1)
    ///   - normalizedY: Normalized Y coordinate (-1 to 1)
    ///   - zoom: Current zoom level
    ///   - panOffset: Current pan offset (panOffset.y is stored inverted)
    ///   - aspectRatio: Aspect ratio correction
    /// - Returns: Texture coordinates (0 to 1), or nil if outside bounds
    public static func screenToTextureCoord(
        normalizedX: Float,
        normalizedY: Float,
        zoom: Float,
        panOffset: SIMD2<Float>,
        aspectRatio: SIMD2<Float>
    ) -> SIMD2<Float>? {
        // The shader transform is: screenPos = (vertexPos * aspectRatio) * zoom + panOffset
        // Note: panOffset.y is stored inverted in Swift, but sent directly to shader
        // So the shader effectively does: screenPos.y = vertexPos.y * zoom + panOffset.y (where panOffset.y is the inverted value)
        // To reverse: vertexPos = (screenPos - panOffset) / zoom / aspectRatio
        let screenPos = SIMD2<Float>(normalizedX, normalizedY)
        
        // Calculate: (screenPos - panOffset) / zoom / aspectRatio
        // For Y: panOffset.y is stored inverted, so we subtract it directly (no negation needed)
        let screenMinusPan = SIMD2<Float>(
            screenPos.x - panOffset.x,
            screenPos.y - panOffset.y
        )
        
        let vertexPos = SIMD2<Float>(
            screenMinusPan.x / zoom / aspectRatio.x,
            screenMinusPan.y / zoom / aspectRatio.y
        )
        
        // Convert vertex position (-1 to 1) to texture coordinates (0 to 1)
        // The quad vertices are:
        // Bottom-left: (-1, -1) with texture (0, 1)
        // Bottom-right: (1, -1) with texture (1, 1)
        // Top-left: (-1, 1) with texture (0, 0)
        // Top-right: (1, 1) with texture (1, 0)
        // So: texX = (vertexX + 1) / 2, texY = 1 - (vertexY + 1) / 2
        let texCoord = SIMD2<Float>(
            (vertexPos.x + 1.0) / 2.0,  // -1 to 1 -> 0 to 1
            1.0 - (vertexPos.y + 1.0) / 2.0  // -1 to 1 -> 1 to 0 (flip Y)
        )
        
        // Check bounds
        guard texCoord.x >= 0.0 && texCoord.x <= 1.0 && texCoord.y >= 0.0 && texCoord.y <= 1.0 else {
            return nil
        }
        
        return texCoord
    }
}

// Direct C function bindings for functions that Swift Package Manager can't see
// Using Swift naming conventions while mapping to C function names
@_silgen_name("fits_movabs_hdu_wrapper")
func moveToHDUPointer(_ fptr: OpaquePointer?, _ hduNumber: Int32, _ hduType: UnsafeMutablePointer<Int32>, _ status: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("fits_get_hdrspace_wrapper")
func getHeaderSpace(_ fptr: OpaquePointer?, _ numKeys: UnsafeMutablePointer<Int32>, _ numMore: UnsafeMutablePointer<Int32>, _ status: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("fits_read_keyn_wrapper")
func readKeyAtIndex(_ fptr: OpaquePointer?, _ index: Int32, _ keyName: UnsafeMutablePointer<CChar>, _ value: UnsafeMutablePointer<CChar>, _ comment: UnsafeMutablePointer<CChar>, _ status: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("fits_get_img_param_wrapper")
func getImageParameters(_ fptr: OpaquePointer?, _ maxDimensions: Int32, _ bitpix: UnsafeMutablePointer<Int32>, _ naxis: UnsafeMutablePointer<Int32>, _ naxes: UnsafeMutablePointer<Int64>, _ status: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("fits_read_img_wrapper")
func readImageData(_ fptr: OpaquePointer?, _ dataType: Int32, _ naxis: Int32, _ firstPixel: UnsafeMutablePointer<Int64>, _ numElements: UnsafeMutablePointer<Int64>, _ nullValue: UnsafeMutablePointer<Float32>?, _ array: UnsafeMutablePointer<Float32>, _ anyNull: UnsafeMutablePointer<Int32>, _ status: UnsafeMutablePointer<Int32>) -> Int32

/// Represents a FITS image with metadata and pixel data
public struct FITSImage: Equatable {
    /// Image dimensions
    public let width: Int
    public let height: Int
    public let depth: Int  // For 3D images
    
    /// Data type information
    public let bitpix: Int32
    public let dataType: FITSDataType
    
    /// Pixel data as Float32 array (normalized for Metal)
    public let pixelData: [Float32]
    
    /// Raw pixel data
    public let rawData: Data
    
    /// Original pixel value range (before normalization)
    public let originalMinValue: Float32
    public let originalMaxValue: Float32
    
    /// Metadata from FITS header
    public let metadata: [String: FITSHeaderValue]
    
    /// Image dimensions as a vector
    public var dimensions: SIMD3<Int> {
        SIMD3<Int>(width, height, depth)
    }
}

/// FITS data type enumeration
public enum FITSDataType: Equatable {
    case byte      // 8-bit signed integer
    case short     // 16-bit signed integer
    case long      // 32-bit signed integer
    case longLong  // 64-bit signed integer
    case float     // 32-bit floating point
    case double    // 64-bit floating point
    
    public var description: String {
        switch self {
        case .byte: return "8-bit signed integer"
        case .short: return "16-bit signed integer"
        case .long: return "32-bit signed integer"
        case .longLong: return "64-bit signed integer"
        case .float: return "32-bit floating point"
        case .double: return "64-bit floating point"
        }
    }
    
    init(bitpix: Int32) throws {
        switch bitpix {
        case 8: self = .byte
        case 16: self = .short
        case 32: self = .long
        case 64: self = .longLong
        case -32: self = .float
        case -64: self = .double
        default:
            throw FITSFileError.unsupportedDataType(bitpix: bitpix)
        }
    }
    
    var bytesPerPixel: Int {
        switch self {
        case .byte: return 1
        case .short: return 2
        case .long: return 4
        case .longLong: return 8
        case .float: return 4
        case .double: return 8
        }
    }
    
    var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .byte: return .r8Unorm
        case .short: return .r16Unorm
        case .long: return .r32Uint
        case .longLong: return .r32Uint  // Metal doesn't support 64-bit textures
        case .float: return .r32Float
        case .double: return .r32Float  // Convert double to float for Metal
        }
    }
    
    /// Creates a FITSDataType from a Metal pixel format.
    /// 
    /// Note: Some conversions are lossy. For example, both `.long` and `.longLong` 
    /// map to `.r32Uint`, and both `.float` and `.double` map to `.r32Float`.
    /// This method assumes the most common mapping (`.long` for `.r32Uint`, `.float` for `.r32Float`).
    /// - Parameter pixelFormat: The Metal pixel format
    /// - Returns: The corresponding FITSDataType, or `nil` if the format is not supported
    static func from(metalPixelFormat pixelFormat: MTLPixelFormat) -> FITSDataType? {
        switch pixelFormat {
        case .r8Unorm, .r8Uint, .r8Sint:
            return .byte
        case .r16Unorm, .r16Uint, .r16Sint, .r16Float:
            return .short
        case .r32Uint, .r32Sint:
            return .long
        case .r32Float:
            return .float
        default:
            return nil
        }
    }
}

/// FITS header value types
public enum FITSHeaderValue: Equatable {
    case string(String)
    case integer(Int64)
    case floatingPoint(Double)
    case boolean(Bool)
    case comment(String)
    
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    
    public var intValue: Int64? {
        if case .integer(let i) = self { return i }
        return nil
    }
    
    public var doubleValue: Double? {
        if case .floatingPoint(let d) = self { return d }
        return nil
    }
    
    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }
}

/// Extension to FITSFile for reading images and metadata
extension FITSFile {
    /// Moves to a specific HDU (Header Data Unit)
    /// - Parameter hduNumber: The HDU number (0 = primary, 1+ = extensions)
    public func moveToHDU(_ hduNumber: Int) throws {
        guard let file = fitsfile else {
            throw FITSFileError.fileNotOpen
        }
        
        var status: Int32 = 0
        var hdutype: Int32 = 0
        _ = moveToHDUPointer(file, Int32(hduNumber + 1), &hdutype, &status)  // CFITSIO uses 1-based indexing
        
        guard status == 0 else {
            var errorText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(status, &errorText)
            errorText[80] = 0
            let errorString = String(cString: errorText)
            Logger.swiftfitsio.error("Error moving to HDU \(hduNumber): status \(status), \(errorString)")
            throw FITSFileError.readError(status: status, message: errorString)
        }
    }
    
    /// Reads all header keywords from the current HDU
    /// - Returns: Dictionary of header keywords and their values
    public func readHeader() throws -> [String: FITSHeaderValue] {
        guard let file = fitsfile else {
            throw FITSFileError.fileNotOpen
        }
        
        var status: Int32 = 0
        var metadata: [String: FITSHeaderValue] = [:]
        
        // Get number of keywords
        var nkeys: Int32 = 0
        var nmore: Int32 = 0
        _ = getHeaderSpace(file, &nkeys, &nmore, &status)
        guard status == 0 else {
            var errorText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(status, &errorText)
            errorText[80] = 0
            let errorString = String(cString: errorText)
            Logger.swiftfitsio.error("Error reading header space: status \(status), \(errorString)")
            throw FITSFileError.readError(status: status, message: errorString)
        }
        
        // Read each keyword.
        // Buffer sizes follow CFITSIO constants:
        //   FLEN_KEYWORD = 75  (HIERARCH keyword names can be up to 74 chars + null)
        //   FLEN_VALUE   = 71  (value up to 70 chars + null)
        //   FLEN_COMMENT = 73  (comment up to 72 chars + null)
        // Using 9 for the keyname buffer is only safe for standard 8-char keywords;
        // HIERARCH keywords overflow a 9-byte buffer and corrupt the null terminator.
        for i in 1...nkeys {
            var keyname = [CChar](repeating: 0, count: 75)  // FLEN_KEYWORD: HIERARCH names up to 74 chars
            var value = [CChar](repeating: 0, count: 71)    // FLEN_VALUE
            var comment = [CChar](repeating: 0, count: 73)  // FLEN_COMMENT
            
            _ = readKeyAtIndex(file, i, &keyname, &value, &comment, &status)
            
            if status == 0 {
                let key = String(cString: keyname).trimmingCharacters(in: .whitespaces)
                let valStr = String(cString: value).trimmingCharacters(in: .whitespaces)
                _ = String(cString: comment).trimmingCharacters(in: .whitespaces)
                
                // Skip END keyword
                if key == "END" { continue }
                
                // Try to parse the value
                if valStr.hasPrefix("'") && valStr.hasSuffix("'") {
                    // String value
                    let str = String(valStr.dropFirst().dropLast())
                    metadata[key] = .string(str)
                } else if valStr.lowercased() == "t" {
                    metadata[key] = .boolean(true)
                } else if valStr.lowercased() == "f" {
                    metadata[key] = .boolean(false)
                } else if let intVal = Int64(valStr) {
                    metadata[key] = .integer(intVal)
                } else if let doubleVal = Double(valStr) {
                    metadata[key] = .floatingPoint(doubleVal)
                } else {
                    metadata[key] = .string(valStr)
                }
            } else {
                // Reset status for non-critical errors
                status = 0
            }
        }
        
        return metadata
    }
    
    /// Reads image data from the current HDU and converts it to Float32 array
    /// - Returns: Tuple containing dimensions, pixel data, raw data, bitpix, and original value range
    public func readImage() throws -> (width: Int, height: Int, depth: Int, pixels: [Float32], rawData: Data, bitpix: Int32, minVal: Float32, maxVal: Float32) {
        guard let file = fitsfile else {
            Logger.swiftfitsio.error("Attempted to read image from closed FITS file")
            throw FITSFileError.fileNotOpen
        }
        
        Logger.swiftfitsio.debug("Reading FITS image data")
        var status: Int32 = 0
        var bitpix: Int32 = 0
        var naxis: Int32 = 0
        var naxes = [Int64](repeating: 0, count: 3)
        
        // Get image parameters
        let naxesLong = [Int](repeating: 0, count: 3)
        var naxesArray = naxesLong.map { Int64($0) }
        _ = getImageParameters(file, 3, &bitpix, &naxis, &naxesArray, &status)
        naxes = naxesArray
        guard status == 0 else {
            var errorText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(status, &errorText)
            errorText[80] = 0
            let errorString = String(cString: errorText)
            Logger.swiftfitsio.error("Error getting image parameters: status \(status), \(errorString)")
            throw FITSFileError.readError(status: status, message: errorString)
        }
        
        let width = Int(naxes[0])
        let height = naxis > 1 ? Int(naxes[1]) : 1
        let depth = naxis > 2 ? Int(naxes[2]) : 1
        
        Logger.swiftfitsio.debug("Image dimensions: \(width)x\(height)x\(depth), bitpix=\(bitpix), naxis=\(naxis)")
        
        // Calculate total pixels
        var totalPixels: Int64 = 1
        for i in 0..<Int(naxis) {
            totalPixels *= naxes[i]
        }
        
        // Read image data - always read as Float32 for Metal compatibility
        // CFITSIO will handle type conversion automatically
        var floatBuffer = [Float32](repeating: 0, count: Int(totalPixels))
        var nullval: Float32 = 0
        var anynull: Int32 = 0
        
        // Use TFLOAT (42) to read as float - CFITSIO handles conversion
        // CFITSIO expects firstPixel and numElements as arrays (one element per dimension)
        // For 2D image: firstPixel = [1, 1], numElements = [width, height]
        let TFLOAT: Int32 = 42
        var firstPixelArray = [Int64](repeating: 1, count: Int(naxis))  // Start at pixel 1,1,1... (1-based)
        var numElementsArray = [Int64](repeating: 0, count: Int(naxis))
        for i in 0..<Int(naxis) {
            numElementsArray[i] = naxes[i]  // Read all pixels in each dimension
        }
        Logger.swiftfitsio.debug("Reading image: firstPixel=\(firstPixelArray), numElements=\(numElementsArray), naxis=\(naxis), totalPixels=\(totalPixels)")
        _ = readImageData(file, TFLOAT, naxis, &firstPixelArray, &numElementsArray, &nullval, &floatBuffer, &anynull, &status)
        
        guard status == 0 else {
            var errorText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(status, &errorText)
            errorText[80] = 0
            let errorString = String(cString: errorText)
            Logger.swiftfitsio.error("Error reading image data: status \(status), \(errorString)")
            throw FITSFileError.readError(status: status, message: errorString)
        }
        
        // Find min/max in one vDSP pass (no Swift loop, vectorised on all cores)
        var minVal: Float32 = 0
        var maxVal: Float32 = 0
        vDSP_minv(floatBuffer, 1, &minVal, vDSP_Length(floatBuffer.count))
        vDSP_maxv(floatBuffer, 1, &maxVal, vDSP_Length(floatBuffer.count))

        // Normalise in-place: subtract min, divide by range — avoids a second [Float32] allocation
        let range = maxVal - minVal
        if range > 0 {
            var negMin = -minVal
            var invRange = 1.0 / range
            // floatBuffer = (floatBuffer + negMin) * invRange
            vDSP_vsadd(floatBuffer, 1, &negMin, &floatBuffer, 1, vDSP_Length(floatBuffer.count))
            vDSP_vsmul(floatBuffer, 1, &invRange, &floatBuffer, 1, vDSP_Length(floatBuffer.count))
        }

        // Capture raw bytes before handing ownership to Data (zero-copy on supported platforms)
        let rawData = floatBuffer.withUnsafeBytes { Data($0) }

        Logger.swiftfitsio.debug("Successfully read image: \(floatBuffer.count) pixels, value range [\(minVal), \(maxVal)]")
        
        return (width, height, depth, floatBuffer, rawData, bitpix, minVal, maxVal)
    }
    
    /// Reads a complete FITS image with metadata
    /// - Parameter hduNumber: Optional HDU number (nil = current HDU)
    /// - Returns: FITSImage structure
    public func readFITSImage(hduNumber: Int? = nil) throws -> FITSImage {
        Logger.swiftfitsio.debug("Reading FITS image (HDU: \(hduNumber?.description ?? "current"))")
        
        if let hdu = hduNumber {
            try moveToHDU(hdu)
        }
        
        // Read metadata
        let metadata = try readHeader()
        Logger.swiftfitsio.debug("Read \(metadata.count) header keywords")
        
        // Read image data
        let (width, height, depth, pixels, rawData, bitpix, minVal, maxVal) = try readImage()
        
        let dataType = try FITSDataType(bitpix: bitpix)
        
        Logger.swiftfitsio.debug("Successfully read FITS image: \(width)x\(height)x\(depth), type=\(dataType.description)")
        
        return FITSImage(
            width: width,
            height: height,
            depth: depth,
            bitpix: bitpix,
            dataType: dataType,
            pixelData: pixels,
            rawData: rawData,
            originalMinValue: minVal,
            originalMaxValue: maxVal,
            metadata: metadata
        )
    }
    
}

/// Extension to create Metal resources from FITS images
extension FITSImage {
    /// Creates a Metal texture from the FITS image data
    /// 
    /// Note: `pixelData` is always stored as `[Float32]` (normalized), so the texture
    /// is always created as `.r32Float` format regardless of the original FITS data type.
    /// The original data type is preserved in the `dataType` field for reference.
    /// - Parameters:
    ///   - device: The Metal device
    ///   - pixelFormat: Optional pixel format (defaults to r32Float, which matches pixelData format)
    /// - Returns: A Metal texture containing the image data
    public func createMetalTexture(device: MTLDevice, pixelFormat: MTLPixelFormat = .r32Float) throws -> MTLTexture {
        // pixelData is always [Float32], so we must use .r32Float format
        // Using a different format would require data conversion and could cause issues
        let actualFormat: MTLPixelFormat = .r32Float
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: actualFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw FITSFileError.readError(status: -1, message: "Failed to create Metal texture")
        }
        
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1))
        
        // Calculate bytes per row for r32Float format
        let bytesPerRow = width * MemoryLayout<Float32>.size
        
        pixelData.withUnsafeBytes { bytes in
            texture.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow)
        }
        
        return texture
    }
    
    /// Creates a Metal buffer from the FITS image data
    /// - Parameter device: The Metal device
    /// - Returns: A Metal buffer containing the pixel data
    public func createMetalBuffer(device: MTLDevice) -> MTLBuffer? {
        let dataSize = pixelData.count * MemoryLayout<Float32>.size
        return device.makeBuffer(bytes: pixelData, length: dataSize, options: [])
    }
    
    /// Gets the pixel value at the specified image coordinates
    /// - Parameters:
    ///   - x: X coordinate in image pixels (0 to width-1)
    ///   - y: Y coordinate in image pixels (0 to height-1)
    /// - Returns: The original (unnormalized) pixel value, or nil if coordinates are out of bounds
    public func getPixelValue(x: Int, y: Int) -> Float32? {
        guard x >= 0 && x < width && y >= 0 && y < height else {
            return nil
        }
        
        // Pixel data is stored row by row (y * width + x)
        let index = y * width + x
        
        guard index < pixelData.count else {
            return nil
        }
        
        // Convert normalized pixel value back to original range
        let normalizedValue = pixelData[index]
        let range = originalMaxValue - originalMinValue
        let originalValue = range > 0 ? normalizedValue * range + originalMinValue : originalMinValue
        
        return originalValue
    }
    
    /// Extracts a region around the specified pixel coordinates
    /// - Parameters:
    ///   - centerX: Center X coordinate in image pixels (0 to width-1)
    ///   - centerY: Center Y coordinate in image pixels (0 to height-1)
    ///   - size: Size of the region to extract (default: 30x30)
    /// - Returns: A new FITSImage containing the extracted region, or nil if coordinates are out of bounds
    public func extractRegion(centerX: Int, centerY: Int, size: Int = 30) -> FITSImage? {
        // Calculate region bounds (centered on the pixel)
        let halfSize = size / 2
        let startX = max(0, centerX - halfSize)
        let startY = max(0, centerY - halfSize)
        let endX = min(width, centerX + halfSize + (size % 2 == 0 ? 0 : 1))
        let endY = min(height, centerY + halfSize + (size % 2 == 0 ? 0 : 1))
        
        let regionWidth = endX - startX
        let regionHeight = endY - startY
        
        guard regionWidth > 0 && regionHeight > 0 else {
            return nil
        }
        
        // Extract pixel data for the region (keep normalized values)
        var regionPixels: [Float32] = []
        regionPixels.reserveCapacity(regionWidth * regionHeight)
        
        for y in startY..<endY {
            for x in startX..<endX {
                let index = y * width + x
                if index < pixelData.count {
                    regionPixels.append(pixelData[index])
                } else {
                    // Pad with zero if out of bounds
                    regionPixels.append(0.0)
                }
            }
        }
        
        // Create raw data
        let regionRawData = regionPixels.withUnsafeBytes { Data($0) }
        
        // Create new FITSImage with the extracted region
        // Use the same original min/max values as the parent image to maintain consistent normalization
        return FITSImage(
            width: regionWidth,
            height: regionHeight,
            depth: depth,
            bitpix: bitpix,
            dataType: dataType,
            pixelData: regionPixels,
            rawData: regionRawData,
            originalMinValue: originalMinValue,
            originalMaxValue: originalMaxValue,
            metadata: metadata
        )
    }
    
    /// Gets cross-section data along the center X-axis (horizontal line through center)
    /// - Returns: Array of pixel values along the center row, converted to original value range
    public func getCenterXCrossSection() -> [Float] {
        let centerY = height / 2
        var values: [Float] = []
        values.reserveCapacity(width)
        
        let range = originalMaxValue - originalMinValue
        
        for x in 0..<width {
            let index = centerY * width + x
            if index < pixelData.count {
                let normalizedValue = pixelData[index]
                // Convert to original value range
                let originalValue = range > 0 ? Float(normalizedValue) * range + originalMinValue : originalMinValue
                values.append(originalValue)
            } else {
                values.append(originalMinValue)
            }
        }
        
        return values
    }
    
    /// Gets cross-section data along the center Y-axis (vertical line through center)
    /// - Returns: Array of pixel values along the center column, converted to original value range
    public func getCenterYCrossSection() -> [Float] {
        let centerX = width / 2
        var values: [Float] = []
        values.reserveCapacity(height)
        
        let range = originalMaxValue - originalMinValue
        
        for y in 0..<height {
            let index = y * width + centerX
            if index < pixelData.count {
                let normalizedValue = pixelData[index]
                // Convert to original value range
                let originalValue = range > 0 ? Float(normalizedValue) * range + originalMinValue : originalMinValue
                values.append(originalValue)
            } else {
                values.append(originalMinValue)
            }
        }
        
        return values
    }
    
    /// Converts normalized screen coordinates (-1 to 1) to image pixel coordinates
    /// - Parameters:
    ///   - normalizedX: Normalized X coordinate (-1 to 1)
    ///   - normalizedY: Normalized Y coordinate (-1 to 1)
    ///   - zoom: Current zoom level
    ///   - panOffset: Current pan offset
    ///   - aspectRatio: Aspect ratio correction
    /// - Returns: Image pixel coordinates (x, y), or nil if outside image bounds
    public func screenToImagePixel(
        normalizedX: Float,
        normalizedY: Float,
        zoom: Float,
        panOffset: SIMD2<Float>,
        aspectRatio: SIMD2<Float>
    ) -> (x: Int, y: Int)? {
        // Use shared coordinate converter
        guard let texCoord = FITSCoordinateConverter.screenToTextureCoord(
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            zoom: zoom,
            panOffset: panOffset,
            aspectRatio: aspectRatio
        ) else {
            return nil
        }
        
        // Convert texture coordinates to image pixel coordinates
        // Texture (0,0) is top-left of image, (1,1) is bottom-right
        // Use floor to get the pixel that contains this texture coordinate (like texture sampling)
        let pixelXFloat = texCoord.x * Float(width)
        let pixelYFloat = texCoord.y * Float(height)
        
        // Convert to integer pixel coordinates
        // Use floor to match how texture sampling works (pixel centers are at 0.5, 1.5, etc.)
        let pixelX = Int(floor(pixelXFloat))
        let pixelY = Int(floor(pixelYFloat))
        
        // Final bounds check
        guard pixelX >= 0 && pixelX < width && pixelY >= 0 && pixelY < height else {
            return nil
        }
        
        return (x: pixelX, y: pixelY)
    }
    
    /// Logs detailed pixel information for debugging (called on click)
    public func logPixelInfo(
        normalizedX: Float,
        normalizedY: Float,
        zoom: Float,
        panOffset: SIMD2<Float>,
        aspectRatio: SIMD2<Float>
    ) {
        Logger.swiftfitsio.debug("screenToImagePixel: Input: normalized=(\(normalizedX), \(normalizedY)), zoom=\(zoom)")
        Logger.swiftfitsio.debug("panOffset=(\(panOffset.x), \(panOffset.y)), aspectRatio=(\(aspectRatio.x), \(aspectRatio.y))")
        
        // Use shared coordinate converter
        guard let texCoord = FITSCoordinateConverter.screenToTextureCoord(
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            zoom: zoom,
            panOffset: panOffset,
            aspectRatio: aspectRatio
        ) else {
            Logger.swiftfitsio.notice("Out of bounds (texture coords)")
            return
        }
        
        Logger.swiftfitsio.debug("FITSCoordinateConverter:")
        let screenPos = SIMD2<Float>(normalizedX, normalizedY)
        let screenMinusPan = SIMD2<Float>(
            screenPos.x - panOffset.x,
            screenPos.y - panOffset.y  // panOffset.y is stored inverted, but shader uses it directly
        )
        let vertexPos = SIMD2<Float>(
            screenMinusPan.x / zoom / aspectRatio.x,
            screenMinusPan.y / zoom / aspectRatio.y
        )
        Logger.swiftfitsio.debug("screenPos=(\(screenPos.x), \(screenPos.y))")
        Logger.swiftfitsio.debug("panOffset=(\(panOffset.x), \(panOffset.y)) [y is stored inverted]")
        Logger.swiftfitsio.debug("zoom=\(zoom), aspectRatio=(\(aspectRatio.x), \(aspectRatio.y))")
        Logger.swiftfitsio.debug("screenMinusPan=(\(screenMinusPan.x), \(screenMinusPan.y))")
        Logger.swiftfitsio.debug("vertexPos=(\(vertexPos.x), \(vertexPos.y))")
        Logger.swiftfitsio.debug("texCoord=(\(texCoord.x), \(texCoord.y))")
        
        // Convert texture coordinates to image pixel coordinates
        let pixelXFloat = texCoord.x * Float(width)
        let pixelYFloat = texCoord.y * Float(height)
        Logger.swiftfitsio.debug("pixelFloat=(\(pixelXFloat), \(pixelYFloat)), imageSize=(\(width), \(height))")
        
        // Convert to integer pixel coordinates
        let pixelX = Int(floor(pixelXFloat))
        let pixelY = Int(floor(pixelYFloat))
        Logger.swiftfitsio.debug("pixelCoords=(\(pixelX), \(pixelY))")
        
        // Final bounds check
        guard pixelX >= 0 && pixelX < width && pixelY >= 0 && pixelY < height else {
            Logger.swiftfitsio.notice("Out of bounds (pixel coords)")
            return
        }
        
        // Get pixel value
        Logger.swiftfitsio.debug("getPixelValue: x=\(pixelX), y=\(pixelY), imageSize=(\(width), \(height))")
        let index = pixelY * width + pixelX
        Logger.swiftfitsio.debug("index=\(index), pixelData.count=\(pixelData.count)")
        
        guard index < pixelData.count else {
            Logger.swiftfitsio.error("Index out of range")
            return
        }
        
        let normalizedValue = pixelData[index]
        let range = originalMaxValue - originalMinValue
        let originalValue = range > 0 ? normalizedValue * range + originalMinValue : originalMinValue
        Logger.swiftfitsio.debug("normalizedValue=\(normalizedValue), range=\(range)")
        Logger.swiftfitsio.debug("originalValue=\(originalValue) (min=\(originalMinValue), max=\(originalMaxValue))")
    }
}


