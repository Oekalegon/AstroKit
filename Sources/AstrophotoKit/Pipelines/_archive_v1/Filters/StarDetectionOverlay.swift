import Foundation
import Metal

/// Structure representing a star ellipse for overlay drawing
public struct StarEllipse {
    public let centroidX: Float
    public let centroidY: Float
    public let majorAxis: Float
    public let minorAxis: Float
    public let rotationAngle: Float // in radians
    
    public init(centroidX: Float, centroidY: Float, majorAxis: Float, minorAxis: Float, rotationAngle: Float) {
        self.centroidX = centroidX
        self.centroidY = centroidY
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
        self.rotationAngle = rotationAngle
    }
}

/// Structure representing a quad line (4 points forming a quadrilateral)
public struct QuadLine {
    public let x1: Float
    public let y1: Float
    public let x2: Float
    public let y2: Float
    public let x3: Float
    public let y3: Float
    public let x4: Float
    public let y4: Float
    
    public init(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float, x4: Float, y4: Float) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.x3 = x3
        self.y3 = y3
        self.x4 = x4
        self.y4 = y4
    }
}

/// Errors that can occur during star detection overlay computation
public enum StarDetectionOverlayError: LocalizedError {
    case metalNotSupported
    case couldNotCreateCommandQueue
    case couldNotLoadShaderLibrary
    case couldNotLoadComputeFunction
    case couldNotCreatePipelineState(Error)
    case couldNotCreateTexture
    case couldNotCreateBuffer
    case couldNotCreateCommandBuffer
    case couldNotCreateComputeEncoder
    case computeError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .metalNotSupported:
            return "Metal is not supported on this device"
        case .couldNotCreateCommandQueue:
            return "Could not create Metal command queue"
        case .couldNotLoadShaderLibrary:
            return "Could not load Metal shader library"
        case .couldNotLoadComputeFunction:
            return "Could not load ellipse overlay compute function"
        case .couldNotCreatePipelineState(let error):
            return "Could not create compute pipeline state: \(error.localizedDescription)"
        case .couldNotCreateTexture:
            return "Could not create Metal texture"
        case .couldNotCreateBuffer:
            return "Could not create Metal buffer"
        case .couldNotCreateCommandBuffer:
            return "Could not create Metal command buffer"
        case .couldNotCreateComputeEncoder:
            return "Could not create Metal compute encoder"
        case .computeError(let error):
            return "Compute shader error: \(error.localizedDescription)"
        }
    }
}

/// Draws ellipses and quads around stars on an image using Metal
public class StarDetectionOverlay {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipelineState: MTLComputePipelineState
    
    public init(device: MTLDevice) throws {
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw StarDetectionOverlayError.couldNotCreateCommandQueue
        }
        self.commandQueue = commandQueue
        
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw StarDetectionOverlayError.couldNotLoadShaderLibrary
        }
        
        guard let function = library.makeFunction(name: "draw_ellipses") else {
            throw StarDetectionOverlayError.couldNotLoadComputeFunction
        }
        
        do {
            self.computePipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw StarDetectionOverlayError.couldNotCreatePipelineState(error)
        }
    }
    
    /// Draws ellipses on an input texture
    /// - Parameters:
    ///   - inputTexture: The input image texture
    ///   - ellipses: Array of star ellipses to draw
    ///   - ellipseColor: RGB color for the ellipses (default: red)
    ///   - ellipseWidth: Line width in pixels (default: 1.0, ignored - always 1 pixel)
    ///   - quads: Array of quads to draw (optional)
    ///   - quadColor: RGB color for the quad lines (default: green)
    ///   - quadWidth: Line width for quads in pixels (default: 1.0)
    /// - Returns: A new texture with ellipses and quads drawn on it
    public func apply(
        to inputTexture: MTLTexture,
        ellipses: [StarEllipse],
        ellipseColor: SIMD3<Float> = SIMD3<Float>(1.0, 0.0, 0.0), // Red by default
        ellipseWidth: Float = 1.0, // Always 1 pixel wide
        quads: [QuadLine] = [],
        quadColor: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0), // Green by default
        quadWidth: Float = 1.0
    ) throws -> MTLTexture {
        guard !ellipses.isEmpty else {
            // If no ellipses, just return a copy of the input
            return try copyTexture(inputTexture)
        }
        
        // Create output texture with RGBA format to support color
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, // Use RGBA to support color
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw StarDetectionOverlayError.couldNotCreateTexture
        }
        
        // First, copy the grayscale input to RGB channels of output
        // This ensures the background image is visible
        try copyGrayscaleToRGBA(inputTexture: inputTexture, outputTexture: outputTexture)
        
        // Create buffer for ellipses
        let ellipseStructSize = MemoryLayout<Float>.size * 5 // centroid(2) + majorAxis + minorAxis + rotationAngle
        let ellipseBufferSize = ellipses.count * ellipseStructSize
        guard let ellipseBuffer = device.makeBuffer(length: ellipseBufferSize, options: [.storageModeShared]) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Fill ellipse buffer
        let ellipsePointer = ellipseBuffer.contents().bindMemory(to: Float.self, capacity: ellipses.count * 5)
        for (index, ellipse) in ellipses.enumerated() {
            let offset = index * 5
            ellipsePointer[offset + 0] = ellipse.centroidX
            ellipsePointer[offset + 1] = ellipse.centroidY
            ellipsePointer[offset + 2] = ellipse.majorAxis
            ellipsePointer[offset + 3] = ellipse.minorAxis
            ellipsePointer[offset + 4] = ellipse.rotationAngle
        }
        
        // Create buffer for number of ellipses
        var numEllipses = Int32(ellipses.count)
        guard let numEllipsesBuffer = device.makeBuffer(bytes: &numEllipses, length: MemoryLayout<Int32>.size, options: []) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Create buffer for ellipse color
        var colorArray: [Float] = [ellipseColor.x, ellipseColor.y, ellipseColor.z]
        guard let colorBuffer = device.makeBuffer(bytes: &colorArray, length: MemoryLayout<Float>.size * 3, options: []) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Create buffer for ellipse width
        var widthValue = ellipseWidth
        guard let widthBuffer = device.makeBuffer(bytes: &widthValue, length: MemoryLayout<Float>.size, options: []) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Create command buffer and encoder
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StarDetectionOverlayError.couldNotCreateCommandBuffer
        }
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw StarDetectionOverlayError.couldNotCreateComputeEncoder
        }
        
        // Set up compute pipeline
        computeEncoder.setComputePipelineState(computePipelineState)
        // Use outputTexture as input since we already copied grayscale to RGBA there
        computeEncoder.setTexture(outputTexture, index: 0) // Read from RGBA output (background)
        computeEncoder.setTexture(outputTexture, index: 1) // Write to same RGBA output (add ellipses)
        computeEncoder.setBuffer(ellipseBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(numEllipsesBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(colorBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(widthBuffer, offset: 0, index: 3)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        // Dispatch compute for ellipses
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw StarDetectionOverlayError.computeError(error)
        }
        
        // Draw quads if provided
        if !quads.isEmpty {
            try drawQuads(
                on: outputTexture,
                quads: quads,
                quadColor: quadColor,
                quadWidth: quadWidth
            )
        }
        
        return outputTexture
    }
    
    /// Helper function to copy grayscale texture to RGBA texture
    private func copyGrayscaleToRGBA(inputTexture: MTLTexture, outputTexture: MTLTexture) throws {
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw StarDetectionOverlayError.couldNotLoadShaderLibrary
        }
        
        guard let function = library.makeFunction(name: "copy_grayscale_to_rgba") else {
            // If shader doesn't exist, use a simple blit (will only copy R channel)
            // This is a fallback
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw StarDetectionOverlayError.couldNotCreateCommandBuffer
            }
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                throw StarDetectionOverlayError.couldNotCreateComputeEncoder
            }
            blitEncoder.copy(
                from: inputTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1),
                to: outputTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw StarDetectionOverlayError.couldNotCreatePipelineState(NSError(domain: "StarDetectionOverlay", code: 1))
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StarDetectionOverlayError.couldNotCreateCommandBuffer
        }
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw StarDetectionOverlayError.couldNotCreateComputeEncoder
        }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw StarDetectionOverlayError.computeError(error)
        }
    }
    
    /// Helper function to copy a texture
    private func copyTexture(_ texture: MTLTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw StarDetectionOverlayError.couldNotCreateTexture
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StarDetectionOverlayError.couldNotCreateCommandBuffer
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw StarDetectionOverlayError.couldNotCreateComputeEncoder
        }
        
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: outputTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw StarDetectionOverlayError.computeError(error)
        }
        
        return outputTexture
    }
    
    /// Draws quad lines on a texture
    private func drawQuads(
        on texture: MTLTexture,
        quads: [QuadLine],
        quadColor: SIMD3<Float>,
        quadWidth: Float
    ) throws {
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw StarDetectionOverlayError.couldNotLoadShaderLibrary
        }
        
        guard let function = library.makeFunction(name: "draw_quads") else {
            throw StarDetectionOverlayError.couldNotLoadComputeFunction
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw StarDetectionOverlayError.couldNotCreatePipelineState(NSError(domain: "StarDetectionOverlay", code: 2))
        }
        
        // Create buffer for quads (8 floats per quad: x1, y1, x2, y2, x3, y3, x4, y4)
        let quadStructSize = MemoryLayout<Float>.size * 8
        let quadBufferSize = quads.count * quadStructSize
        guard let quadBuffer = device.makeBuffer(length: quadBufferSize, options: [.storageModeShared]) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Fill quad buffer
        let quadPointer = quadBuffer.contents().bindMemory(to: Float.self, capacity: quads.count * 8)
        for (index, quad) in quads.enumerated() {
            let offset = index * 8
            quadPointer[offset + 0] = quad.x1
            quadPointer[offset + 1] = quad.y1
            quadPointer[offset + 2] = quad.x2
            quadPointer[offset + 3] = quad.y2
            quadPointer[offset + 4] = quad.x3
            quadPointer[offset + 5] = quad.y3
            quadPointer[offset + 6] = quad.x4
            quadPointer[offset + 7] = quad.y4
        }
        
        // Create buffer for number of quads
        var numQuads = Int32(quads.count)
        guard let numQuadsBuffer = device.makeBuffer(bytes: &numQuads, length: MemoryLayout<Int32>.size, options: []) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Create buffer for quad color
        var colorArray: [Float] = [quadColor.x, quadColor.y, quadColor.z]
        guard let colorBuffer = device.makeBuffer(bytes: &colorArray, length: MemoryLayout<Float>.size * 3, options: []) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        // Create buffer for quad width
        var widthValue = quadWidth
        guard let widthBuffer = device.makeBuffer(bytes: &widthValue, length: MemoryLayout<Float>.size, options: []) else {
            throw StarDetectionOverlayError.couldNotCreateBuffer
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw StarDetectionOverlayError.couldNotCreateCommandBuffer
        }
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw StarDetectionOverlayError.couldNotCreateComputeEncoder
        }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(texture, index: 0) // Read from
        computeEncoder.setTexture(texture, index: 1) // Write to
        computeEncoder.setBuffer(quadBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(numQuadsBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(colorBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(widthBuffer, offset: 0, index: 3)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw StarDetectionOverlayError.computeError(error)
        }
    }
}

