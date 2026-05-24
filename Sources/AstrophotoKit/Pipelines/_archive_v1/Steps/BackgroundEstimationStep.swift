import Foundation
import Metal

/// Pipeline step that estimates and extracts the background from an image
public class BackgroundEstimationStep: PipelineStep {
    public let id: String = "background_estimation"
    public let name: String = "Background Estimation"
    public let description: String = "Estimates the background level and extracts it from the image"
    
    public let requiredInputs: [String] = ["blurred_image"]
    public let optionalInputs: [String] = ["method", "window_size"]
    public let outputs: [String] = ["background_image", "background_subtracted_image", "background_level"]
    
    private let defaultMethod: BackgroundEstimationMethod
    private let defaultWindowSize: Int
    
    /// Method for background estimation
    public enum BackgroundEstimationMethod: String {
        case median = "median"
        case mean = "mean"
        case percentile = "percentile"
    }
    
    /// Initialize the background estimation step
    /// - Parameters:
    ///   - defaultMethod: Default estimation method (default: .median)
    ///   - defaultWindowSize: Default window size for local estimation (default: 50)
    public init(defaultMethod: BackgroundEstimationMethod = .median, defaultWindowSize: Int = 50) {
        self.defaultMethod = defaultMethod
        self.defaultWindowSize = defaultWindowSize
    }
    
    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        // Get input image (try blurred_image first, then fall back to input_image for flexibility)
        guard let inputImageInput = inputs["blurred_image"] ?? inputs["input_image"] else {
            throw PipelineStepError.missingRequiredInput("blurred_image or input_image")
        }
        
        // Get method (optional)
        let method: BackgroundEstimationMethod
        if let methodInput = inputs["method"] {
            if let methodString = methodInput.data.metadata?["method"] as? String,
               let methodValue = BackgroundEstimationMethod(rawValue: methodString) {
                method = methodValue
            } else {
                method = defaultMethod
            }
        } else {
            method = defaultMethod
        }
        
        // Get window size (optional)
        let windowSize: Int
        if let windowSizeInput = inputs["window_size"] {
            if let windowSizeValue = windowSizeInput.data.scalar.map({ Int($0) }) {
                windowSize = windowSizeValue
            } else {
                windowSize = defaultWindowSize
            }
        } else {
            windowSize = defaultWindowSize
        }
        
        // Get input ProcessedImage or create one from texture/FITSImage
        let inputProcessedImage: ProcessedImage
        if let processedImage = inputImageInput.data.processedImage {
            inputProcessedImage = processedImage
        } else if let texture = inputImageInput.data.texture {
            // Create ProcessedImage from texture
            let imageType = ProcessedImage.imageType(from: texture.pixelFormat)
            inputProcessedImage = ProcessedImage(
                texture: texture,
                imageType: imageType,
                originalMinValue: 0.0,
                originalMaxValue: 1.0,
                processingHistory: [],
                fitsImage: inputImageInput.data.fitsImage,
                name: inputImageInput.name
            )
        } else if let fitsImage = inputImageInput.data.fitsImage {
            inputProcessedImage = try ProcessedImage.fromFITSImage(fitsImage, device: device)
        } else {
            throw PipelineStepError.invalidInputType("input_image", expected: "processedImage, texture, or fitsImage")
        }
        
        let inputTexture = inputProcessedImage.texture
        
        // Use GPU-based local median estimation
        let backgroundTexture = try estimateLocalBackground(
            texture: inputTexture,
            method: method,
            windowSize: windowSize,
            device: device,
            commandQueue: commandQueue
        )
        
        // Create background-subtracted image using local background
        let backgroundSubtractedTexture = try subtractLocalBackground(
            texture: inputTexture,
            backgroundTexture: backgroundTexture,
            device: device,
            commandQueue: commandQueue
        )
        
        // Calculate average background level for scalar output (for compatibility)
        let backgroundLevel = try calculateAverageBackgroundLevel(
            texture: backgroundTexture,
            device: device,
            commandQueue: commandQueue
        )
        
        // Create output ProcessedImages with processing history
        // Use different parameters to distinguish the two outputs
        let backgroundParameters: [String: String] = [
            "method": method.rawValue,
            "window_size": "\(windowSize)",
            "output": "background_image"
        ]
        
        let backgroundSubtractedParameters: [String: String] = [
            "method": method.rawValue,
            "window_size": "\(windowSize)",
            "output": "background_subtracted_image"
        ]
        
        let backgroundProcessedImage = inputProcessedImage.withProcessingStep(
            stepID: id,
            stepName: "\(name) (Background)",
            parameters: backgroundParameters,
            newTexture: backgroundTexture,
            newImageType: inputProcessedImage.imageType, // Background preserves image type
            newName: "Background Image"
        )
        
        let backgroundSubtractedProcessedImage = inputProcessedImage.withProcessingStep(
            stepID: id,
            stepName: "\(name) (Subtracted)",
            parameters: backgroundSubtractedParameters,
            newTexture: backgroundSubtractedTexture,
            newImageType: inputProcessedImage.imageType, // Background subtraction preserves image type
            newName: "Background Subtracted Image"
        )
        
        // Create ProcessedScalar with processing history from input image
        let backgroundLevelParameters: [String: String] = [
            "method": method.rawValue,
            "window_size": "\(windowSize)",
            "output": "background_level"
        ]
        
        let baseProcessedScalar = ProcessedScalar(
            value: backgroundLevel,
            processingHistory: inputProcessedImage.processingHistory,
            name: "Background Level"
        )
        
        let backgroundLevelProcessedScalar = baseProcessedScalar.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: backgroundLevelParameters,
            newValue: backgroundLevel,
            newName: "Background Level",
            newUnit: "ADU"
        )
        
        return [
            "background_image": PipelineStepOutput(
                name: "background_image",
                data: .processedImage(backgroundProcessedImage),
                description: "The estimated background image"
            ),
            "background_subtracted_image": PipelineStepOutput(
                name: "background_subtracted_image",
                data: .processedImage(backgroundSubtractedProcessedImage),
                description: "The image with background subtracted"
            ),
            "background_level": PipelineStepOutput(
                name: "background_level",
                data: .processedScalar(backgroundLevelProcessedScalar),
                description: "The estimated background level"
            )
        ]
    }
    
    // MARK: - Private Helper Methods
    
    /// Estimate local background using GPU-based local median
    private func estimateLocalBackground(
        texture: MTLTexture,
        method: BackgroundEstimationMethod,
        windowSize: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Only median method is supported for local estimation on GPU
        // Mean and percentile would require different implementations
        guard method == .median else {
            // Fall back to global estimation for mean/percentile
            let globalLevel = try estimateGlobalBackground(
                texture: texture,
                method: method,
                device: device,
                commandQueue: commandQueue
            )
            return try createUniformBackgroundTexture(
                texture: texture,
                level: globalLevel,
                device: device,
                commandQueue: commandQueue
            )
        }
        
        // Create output texture for local background
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineStepError.couldNotCreateResource("output texture")
        }
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let function = library.makeFunction(name: "local_median") else {
            throw PipelineStepError.couldNotCreateResource("local_median function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Get image value range from texture (we'll use a reasonable default if not available)
        // For now, assume normalized texture values represent the full dynamic range
        let imageMinValue: Float = 0.0
        let imageMaxValue: Float = 1.0
        
        // Create buffers for parameters
        var windowSizeInt = Int32(windowSize)
        var minValue = imageMinValue
        var maxValue = imageMaxValue
        
        guard let windowSizeBuffer = device.makeBuffer(bytes: &windowSizeInt, length: MemoryLayout<Int32>.size, options: []),
              let minValueBuffer = device.makeBuffer(bytes: &minValue, length: MemoryLayout<Float>.size, options: []),
              let maxValueBuffer = device.makeBuffer(bytes: &maxValue, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("parameter buffers")
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(windowSizeBuffer, offset: 0, index: 0)
        encoder.setBuffer(minValueBuffer, offset: 0, index: 1)
        encoder.setBuffer(maxValueBuffer, offset: 0, index: 2)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("GPU local median estimation failed: \(error.localizedDescription)")
        }
        
        return outputTexture
    }
    
    /// Fallback: Estimate global background using CPU (for mean/percentile methods)
    private func estimateGlobalBackground(
        texture: MTLTexture,
        method: BackgroundEstimationMethod,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        // Read texture data to CPU for estimation
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * MemoryLayout<Float32>.size
        let bufferSize = bytesPerRow * height
        
        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("read buffer")
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("blit encoder")
        }
        
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("Failed to read texture: \(error.localizedDescription)")
        }
        
        // Extract pixel values
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: width * height)
        let pixels = Array(UnsafeBufferPointer(start: pixelPointer, count: width * height))
        
        // Calculate background based on method
        switch method {
        case .median:
            let sorted = pixels.sorted()
            let medianIndex = sorted.count / 2
            return sorted[medianIndex]
        case .mean:
            return pixels.reduce(0, +) / Float(pixels.count)
        case .percentile:
            // Use 25th percentile as background estimate
            let sorted = pixels.sorted()
            let percentileIndex = sorted.count / 4
            return sorted[percentileIndex]
        }
    }
    
    /// Calculate average background level from background texture (for scalar output)
    private func calculateAverageBackgroundLevel(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        // Read a sample of pixels to estimate average (for performance)
        // We'll sample every Nth pixel instead of reading the entire texture
        let sampleRate = 10 // Sample every 10th pixel
        let width = texture.width
        let height = texture.height
        let sampleWidth = width / sampleRate
        let sampleHeight = height / sampleRate
        let bytesPerRow = sampleWidth * MemoryLayout<Float32>.size
        let bufferSize = bytesPerRow * sampleHeight
        
        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("read buffer")
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("blit encoder")
        }
        
        // Sample a region (top-left corner as representative)
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sampleWidth, height: sampleHeight, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("Failed to read texture: \(error.localizedDescription)")
        }
        
        // Calculate average from sample
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: sampleWidth * sampleHeight)
        let pixels = Array(UnsafeBufferPointer(start: pixelPointer, count: sampleWidth * sampleHeight))
        return pixels.reduce(0, +) / Float(pixels.count)
    }
    
    /// Subtract local background texture from input texture
    private func subtractLocalBackground(
        texture: MTLTexture,
        backgroundTexture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineStepError.couldNotCreateResource("output texture")
        }
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let function = library.makeFunction(name: "local_median_subtract") else {
            throw PipelineStepError.couldNotCreateResource("local_median_subtract function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Get image value range
        let imageMinValue: Float = 0.0
        let imageMaxValue: Float = 1.0
        
        // Create buffers for parameters
        var minValue = imageMinValue
        var maxValue = imageMaxValue
        
        guard let minValueBuffer = device.makeBuffer(bytes: &minValue, length: MemoryLayout<Float>.size, options: []),
              let maxValueBuffer = device.makeBuffer(bytes: &maxValue, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("parameter buffers")
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(backgroundTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBuffer(minValueBuffer, offset: 0, index: 0)
        encoder.setBuffer(maxValueBuffer, offset: 0, index: 1)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("GPU local background subtraction failed: \(error.localizedDescription)")
        }
        
        return outputTexture
    }
    
    /// Legacy: Subtract constant background level (kept for compatibility)
    private func subtractBackground(
        texture: MTLTexture,
        backgroundLevel: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineStepError.couldNotCreateResource("output texture")
        }
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let function = library.makeFunction(name: "background_subtract") else {
            throw PipelineStepError.couldNotCreateResource("background_subtract function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Create buffer for background level
        var backgroundLevelValue = backgroundLevel
        guard let backgroundBuffer = device.makeBuffer(bytes: &backgroundLevelValue, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("background level buffer")
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(backgroundBuffer, offset: 0, index: 0)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("GPU background subtraction failed: \(error.localizedDescription)")
        }
        
        return outputTexture
    }
    
    private func createUniformBackgroundTexture(
        texture: MTLTexture,
        level: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineStepError.couldNotCreateResource("output texture")
        }
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let function = library.makeFunction(name: "background_fill") else {
            throw PipelineStepError.couldNotCreateResource("background_fill function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Create buffer for background level
        var backgroundLevelValue = level
        guard let backgroundBuffer = device.makeBuffer(bytes: &backgroundLevelValue, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("background level buffer")
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(outputTexture, index: 0)
        encoder.setBuffer(backgroundBuffer, offset: 0, index: 0)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            throw PipelineStepError.executionFailed("GPU background fill failed: \(error.localizedDescription)")
        }
        
        return outputTexture
    }
}

