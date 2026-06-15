import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Errors that can occur when converting textures to JPEG
public enum TextureToJPEGError: LocalizedError {
    case couldNotCreateCommandBuffer
    case couldNotCreateBlitEncoder
    case couldNotReadTextureData
    case unsupportedPixelFormat(MTLPixelFormat)
    case couldNotCreateCGImage
    case couldNotCreateJPEGData
    case couldNotWriteFile(URL)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateCommandBuffer:
            return "Could not create Metal command buffer"
        case .couldNotCreateBlitEncoder:
            return "Could not create Metal blit encoder"
        case .couldNotReadTextureData:
            return "Could not read texture data from GPU"
        case .unsupportedPixelFormat(let format):
            return "Unsupported pixel format: \(format.rawValue)"
        case .couldNotCreateCGImage:
            return "Could not create CGImage from texture data"
        case .couldNotCreateJPEGData:
            return "Could not create JPEG data from image"
        case .couldNotWriteFile(let url):
            return "Could not write file to: \(url.path)"
        }
    }
}

/// Utility for converting Metal textures to JPEG files
public enum TextureToJPEG {
    /// Converts a Metal texture to a JPEG file
    /// - Parameters:
    ///   - texture: The Metal texture to convert
    ///   - url: The file URL where the JPEG should be saved
    ///   - device: The Metal device (used for reading texture data)
    ///   - commandQueue: The Metal command queue (used for reading texture data)
    ///   - quality: JPEG quality (0.0 to 1.0, default: 0.9)
    /// - Throws: TextureToJPEGError if conversion fails
    public static func save(
        texture: MTLTexture,
        to url: URL,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        quality: Float = 0.9
    ) throws {
        // Read texture data from GPU
        let pixelData = try readTextureData(
            texture: texture,
            device: device,
            commandQueue: commandQueue
        )

        // Create CGImage from pixel data
        let cgImage = try createCGImage(
            from: pixelData,
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )

        // Convert to JPEG and save
        try saveCGImageAsJPEG(cgImage: cgImage, to: url, quality: quality)
    }

    /// Reads texture data from GPU to CPU
    private static func readTextureData(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Data {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = bytesPerPixel(for: texture.pixelFormat)
        let bytesPerRow = width * bytesPerPixel
        let bufferSize = height * bytesPerRow

        // Create a buffer to hold the texture data
        guard let buffer = device.makeBuffer(
            length: bufferSize,
            options: [.storageModeShared]
        ) else {
            throw TextureToJPEGError.couldNotReadTextureData
        }

        // Create command buffer and blit encoder to copy texture to buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw TextureToJPEGError.couldNotCreateCommandBuffer
        }

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw TextureToJPEGError.couldNotCreateBlitEncoder
        }

        // Copy texture to buffer
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.error != nil {
            throw TextureToJPEGError.couldNotReadTextureData
        }

        // Copy buffer data to Data
        let contents = buffer.contents()
        return Data(bytes: contents, count: bufferSize)
    }

    /// Creates a CGImage from pixel data
    private static func createCGImage(
        from data: Data,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> CGImage {
        // Convert pixel data to 8-bit RGB or grayscale
        let (rgbData, colorSpace, bitsPerComponent, bitsPerPixel): (Data, CGColorSpace, Int, Int)

        switch pixelFormat {
        case .r32Float, .r16Float, .r8Unorm:
            // Grayscale - convert to 8-bit grayscale
            rgbData = try convertGrayscaleTo8Bit(
                data: data,
                width: width,
                height: height,
                pixelFormat: pixelFormat
            )
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitsPerComponent = 8
            bitsPerPixel = 8

        case .rgba32Float, .rgba16Float, .rgba8Unorm, .bgra8Unorm:
            // RGBA - convert to 8-bit RGB
            rgbData = try convertRGBATo8BitRGB(
                data: data,
                width: width,
                height: height,
                pixelFormat: pixelFormat
            )
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitsPerComponent = 8
            bitsPerPixel = 24

        default:
            throw TextureToJPEGError.unsupportedPixelFormat(pixelFormat)
        }

        // Create CGImage
        guard let dataProvider = CGDataProvider(data: rgbData as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: bitsPerComponent,
                  bitsPerPixel: bitsPerPixel,
                  bytesPerRow: width * (bitsPerPixel / 8),
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: dataProvider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw TextureToJPEGError.couldNotCreateCGImage
        }

        return cgImage
    }

    /// Converts grayscale texture data to 8-bit grayscale
    private static func convertGrayscaleTo8Bit(
        data: Data,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> Data {
        var outputData = Data(count: width * height)

        switch pixelFormat {
        case .r32Float:
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float32.self)
                for i in 0..<(width * height) {
                    let value = floats[i]
                    // Normalize to 0-255, clamping to valid range
                    let normalized = max(0.0, min(1.0, value))
                    outputData[i] = UInt8(normalized * 255.0)
                }
            }

        case .r16Float:
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float16.self)
                for i in 0..<(width * height) {
                    let value = Float(floats[i])
                    let normalized = max(0.0, min(1.0, value))
                    outputData[i] = UInt8(normalized * 255.0)
                }
            }

        case .r8Unorm:
            // Already 8-bit, just copy
            outputData = data

        default:
            throw TextureToJPEGError.unsupportedPixelFormat(pixelFormat)
        }

        return outputData
    }

    /// Converts RGBA texture data to 8-bit RGB (discarding alpha)
    private static func convertRGBATo8BitRGB(
        data: Data,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> Data {
        var outputData = Data(count: width * height * 3)

        switch pixelFormat {
        case .rgba32Float:
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float32.self)
                var outputIndex = 0
                for i in stride(from: 0, to: width * height * 4, by: 4) {
                    let r = max(0.0, min(1.0, floats[i + 0]))
                    let g = max(0.0, min(1.0, floats[i + 1]))
                    let b = max(0.0, min(1.0, floats[i + 2]))
                    // Skip alpha (i + 3)
                    outputData[outputIndex + 0] = UInt8(r * 255.0)
                    outputData[outputIndex + 1] = UInt8(g * 255.0)
                    outputData[outputIndex + 2] = UInt8(b * 255.0)
                    outputIndex += 3
                }
            }

        case .rgba16Float:
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float16.self)
                var outputIndex = 0
                for i in stride(from: 0, to: width * height * 4, by: 4) {
                    let r = max(0.0, min(1.0, Float(floats[i + 0])))
                    let g = max(0.0, min(1.0, Float(floats[i + 1])))
                    let b = max(0.0, min(1.0, Float(floats[i + 2])))
                    outputData[outputIndex + 0] = UInt8(r * 255.0)
                    outputData[outputIndex + 1] = UInt8(g * 255.0)
                    outputData[outputIndex + 2] = UInt8(b * 255.0)
                    outputIndex += 3
                }
            }

        case .rgba8Unorm, .bgra8Unorm:
            // Already 8-bit, just extract RGB (skip alpha)
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var outputIndex = 0
                for i in stride(from: 0, to: width * height * 4, by: 4) {
                    if pixelFormat == .bgra8Unorm {
                        // BGRA format - swap B and R
                        outputData[outputIndex + 0] = bytes[i + 2] // R
                        outputData[outputIndex + 1] = bytes[i + 1] // G
                        outputData[outputIndex + 2] = bytes[i + 0] // B
                    } else {
                        // RGBA format
                        outputData[outputIndex + 0] = bytes[i + 0] // R
                        outputData[outputIndex + 1] = bytes[i + 1] // G
                        outputData[outputIndex + 2] = bytes[i + 2] // B
                    }
                    outputIndex += 3
                }
            }

        default:
            throw TextureToJPEGError.unsupportedPixelFormat(pixelFormat)
        }

        return outputData
    }

    /// Saves a CGImage as a JPEG file
    private static func saveCGImageAsJPEG(
        cgImage: CGImage,
        to url: URL,
        quality: Float
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TextureToJPEGError.couldNotCreateJPEGData
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TextureToJPEGError.couldNotCreateJPEGData
        }
    }

    /// Returns the number of bytes per pixel for a given pixel format
    private static func bytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .r8Unorm:
            return 1
        case .r16Float:
            return 2
        case .r32Float:
            return 4
        case .rgba8Unorm, .bgra8Unorm:
            return 4
        case .rgba16Float:
            return 8
        case .rgba32Float:
            return 16
        default:
            // Default to 4 bytes for unknown formats
            return 4
        }
    }
}

