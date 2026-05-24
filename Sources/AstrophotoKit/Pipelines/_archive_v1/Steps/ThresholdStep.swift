import Foundation
import Metal

/// Pipeline step that applies a threshold to an image
public class ThresholdStep: PipelineStep {
    public let id: String = "threshold"
    public let name: String = "Threshold"
    public let description: String = "Applies a threshold to create a binary mask of detected objects"
    
    public let requiredInputs: [String] = ["background_subtracted_image"]
    public let optionalInputs: [String] = ["threshold_value", "method"]
    public let outputs: [String] = ["thresholded_image"]
    
    private let defaultThreshold: Float
    private let defaultMethod: ThresholdMethod
    
    /// Method for threshold calculation
    public enum ThresholdMethod: String {
        case fixed = "fixed"
        case adaptive = "adaptive"
        case otsu = "otsu"
        case sigma = "sigma"
        case mad = "mad"
        case percentile = "percentile"
    }
    
    /// Initialize the threshold step
    /// - Parameters:
    ///   - defaultThreshold: Default threshold value (default: 3.0 for sigma method)
    ///   - defaultMethod: Default threshold method (default: .sigma)
    public init(defaultThreshold: Float = 3.0, defaultMethod: ThresholdMethod = .sigma) {
        self.defaultThreshold = defaultThreshold
        self.defaultMethod = defaultMethod
    }
    
    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        // Get input image (try background_subtracted_image first, then fall back to input_image for flexibility)
        guard let inputImageInput = inputs["background_subtracted_image"] ?? inputs["input_image"] else {
            throw PipelineStepError.missingRequiredInput("background_subtracted_image or input_image")
        }
        
        // Get threshold value (optional)
        let threshold: Float
        if let thresholdInput = inputs["threshold_value"] {
            guard let thresholdValue = thresholdInput.data.scalar else {
                throw PipelineStepError.invalidInputType("threshold_value", expected: "scalar")
            }
            threshold = thresholdValue
        } else {
            threshold = defaultThreshold
        }
        
        // Get method (optional)
        let method: ThresholdMethod
        if let methodInput = inputs["method"] {
            if let methodString = methodInput.data.metadata?["method"] as? String,
               let methodValue = ThresholdMethod(rawValue: methodString) {
                method = methodValue
            } else {
                method = defaultMethod
            }
        } else {
            method = defaultMethod
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
        
        // Calculate actual threshold based on method
        let actualThreshold: Float
        switch method {
        case .fixed:
            actualThreshold = threshold
        case .adaptive:
            // TODO: Implement adaptive threshold
            actualThreshold = threshold
        case .otsu:
            actualThreshold = try calculateOtsuThreshold(
                texture: inputTexture,
                device: device,
                commandQueue: commandQueue
            )
        case .sigma:
            // threshold parameter is used as the number of standard deviations (e.g., 3.0 for 3-sigma)
            actualThreshold = try calculateSigmaThreshold(
                texture: inputTexture,
                sigmaMultiplier: threshold,
                device: device,
                commandQueue: commandQueue
            )
        case .mad:
            // threshold parameter is used as the number of MADs (e.g., 3.0 for 3*MAD)
            actualThreshold = try calculateMADThreshold(
                texture: inputTexture,
                madMultiplier: threshold,
                device: device,
                commandQueue: commandQueue
            )
        case .percentile:
            // threshold parameter is used as the percentile (0.0-1.0, e.g., 0.95 for 95th percentile)
            actualThreshold = try calculatePercentileThreshold(
                texture: inputTexture,
                percentile: threshold,
                device: device,
                commandQueue: commandQueue
            )
        }
        
        // Apply threshold
        let thresholdedTexture = try applyThreshold(
            texture: inputTexture,
            threshold: actualThreshold,
            device: device,
            commandQueue: commandQueue
        )
        
        // Create output ProcessedImage with processing history
        var parameters: [String: String] = [
            "method": method.rawValue,
            "threshold": "\(actualThreshold)"
        ]
        if method != .fixed {
            parameters["threshold_parameter"] = "\(threshold)"
        }
        
        let outputProcessedImage = inputProcessedImage.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: parameters,
            newTexture: thresholdedTexture,
            newImageType: .binary, // Threshold produces binary images
            newName: "Thresholded Image"
        )
        
        return [
            "thresholded_image": PipelineStepOutput(
                name: "thresholded_image",
                data: .processedImage(outputProcessedImage),
                description: "The thresholded image (0 or 1 per pixel)"
            )
        ]
    }
    
    // MARK: - Private Helper Methods
    
    private func calculateOtsuThreshold(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        // Read texture data
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
        
        // Extract pixel values
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: width * height)
        let pixels = Array(UnsafeBufferPointer(start: pixelPointer, count: width * height))
        
        // Calculate Otsu's threshold
        // Build histogram (256 bins)
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in pixels {
            let bin = min(255, Int(pixel * 255.0))
            histogram[bin] += 1
        }
        
        let totalPixels = width * height
        var sum: Int = 0
        for i in 0..<256 {
            sum += i * histogram[i]
        }
        
        var sumB: Int = 0
        var wB: Int = 0
        var wF: Int = 0
        var maxVariance: Float = 0
        var threshold: Int = 0
        
        for i in 0..<256 {
            wB += histogram[i]
            if wB == 0 { continue }
            wF = totalPixels - wB
            if wF == 0 { break }
            
            sumB += i * histogram[i]
            let mB = Float(sumB) / Float(wB)
            let mF = Float(sum - sumB) / Float(wF)
            let variance = Float(wB) * Float(wF) * (mB - mF) * (mB - mF)
            
            if variance > maxVariance {
                maxVariance = variance
                threshold = i
            }
        }
        
        return Float(threshold) / 255.0
    }
    
    private func calculateSigmaThreshold(
        texture: MTLTexture,
        sigmaMultiplier: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        let (mean, stdDev) = try calculateMeanAndStdDev(
            texture: texture,
            device: device,
            commandQueue: commandQueue
        )
        // Threshold = mean + N * sigma (for detecting bright objects)
        return mean + sigmaMultiplier * stdDev
    }
    
    private func calculateMADThreshold(
        texture: MTLTexture,
        madMultiplier: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        let (median, mad) = try calculateMedianAndMAD(
            texture: texture,
            device: device,
            commandQueue: commandQueue
        )
        // Threshold = median + N * MAD (for detecting bright objects)
        return median + madMultiplier * mad
    }
    
    private func calculatePercentileThreshold(
        texture: MTLTexture,
        percentile: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        // Read texture data
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
        
        // Extract pixel values
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: width * height)
        let pixels = Array(UnsafeBufferPointer(start: pixelPointer, count: width * height))
        
        // Sort pixels
        let sortedPixels = pixels.sorted()
        
        // Calculate percentile index
        let percentileIndex = Int(Float(sortedPixels.count - 1) * percentile)
        let clampedIndex = min(max(0, percentileIndex), sortedPixels.count - 1)
        
        return sortedPixels[clampedIndex]
    }
    
    private func calculateMeanAndStdDev(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> (mean: Float, stdDev: Float) {
        // Get image value range (assume normalized [0,1] for now, will need to pass actual range)
        // For now, we'll use a reasonable default range
        let imageMinValue: Float = 0.0
        let imageMaxValue: Float = 1.0
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let function = library.makeFunction(name: "calculate_mean_stddev") else {
            throw PipelineStepError.couldNotCreateResource("calculate_mean_stddev function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Create atomic buffers for sum and sum of squares
        // Use atomic_float which requires proper alignment
        guard let sumBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("sum buffer")
        }
        guard let sumSqBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("sumSq buffer")
        }
        
        // Initialize buffers to zero
        let sumPointer = sumBuffer.contents().bindMemory(to: Float.self, capacity: 1)
        let sumSqPointer = sumSqBuffer.contents().bindMemory(to: Float.self, capacity: 1)
        sumPointer[0] = 0.0
        sumSqPointer[0] = 0.0
        
        // Create buffers for constants
        var minVal = imageMinValue
        var maxVal = imageMaxValue
        guard let minBuffer = device.makeBuffer(bytes: &minVal, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("min buffer")
        }
        guard let maxBuffer = device.makeBuffer(bytes: &maxVal, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("max buffer")
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
        encoder.setBuffer(sumBuffer, offset: 0, index: 0)
        encoder.setBuffer(sumSqBuffer, offset: 0, index: 1)
        encoder.setBuffer(minBuffer, offset: 0, index: 2)
        encoder.setBuffer(maxBuffer, offset: 0, index: 3)
        
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
            throw PipelineStepError.executionFailed("GPU mean/stddev calculation failed: \(error.localizedDescription)")
        }
        
        // Read results
        let totalPixels = Float(texture.width * texture.height)
        let sum = sumPointer[0]
        let sumSq = sumSqPointer[0]
        
        let mean = sum / totalPixels
        let variance = (sumSq / totalPixels) - (mean * mean)
        let stdDev = sqrt(max(0.0, variance)) // Ensure non-negative
        
        return (mean, stdDev)
    }
    
    private func calculateMedianAndMAD(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> (median: Float, mad: Float) {
        // Get image value range (assume normalized [0,1] for now)
        let imageMinValue: Float = 0.0
        let imageMaxValue: Float = 1.0
        let numBins = 1024 // Use 1024 bins for better precision
        
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }
        
        guard let histogramFunction = library.makeFunction(name: "build_histogram") else {
            throw PipelineStepError.couldNotCreateResource("build_histogram function")
        }
        
        guard let histogramPipelineState = try? device.makeComputePipelineState(function: histogramFunction) else {
            throw PipelineStepError.couldNotCreateResource("histogram compute pipeline state")
        }
        
        // Create histogram buffer (atomic integers)
        let histogramBufferSize = numBins * MemoryLayout<Int32>.size
        guard let histogramBuffer = device.makeBuffer(length: histogramBufferSize, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("histogram buffer")
        }
        
        // Initialize histogram to zero
        let histogramPointer = histogramBuffer.contents().bindMemory(to: Int32.self, capacity: numBins)
        for i in 0..<numBins {
            histogramPointer[i] = 0
        }
        
        // Create buffers for constants
        var minVal = imageMinValue
        var maxVal = imageMaxValue
        var numBinsVal = Int32(numBins)
        guard let minBuffer = device.makeBuffer(bytes: &minVal, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("min buffer")
        }
        guard let maxBuffer = device.makeBuffer(bytes: &maxVal, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("max buffer")
        }
        guard let numBinsBuffer = device.makeBuffer(bytes: &numBinsVal, length: MemoryLayout<Int32>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("numBins buffer")
        }
        
        // Build histogram on GPU
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        encoder.setComputePipelineState(histogramPipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        encoder.setBuffer(numBinsBuffer, offset: 0, index: 1)
        encoder.setBuffer(minBuffer, offset: 0, index: 2)
        encoder.setBuffer(maxBuffer, offset: 0, index: 3)
        
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
            throw PipelineStepError.executionFailed("GPU histogram calculation failed: \(error.localizedDescription)")
        }
        
        // Find median from histogram
        let totalPixels = texture.width * texture.height
        let targetCount = totalPixels / 2
        var cumulativeCount = 0
        var medianBin = 0
        
        for i in 0..<numBins {
            cumulativeCount += Int(histogramPointer[i])
            if cumulativeCount >= targetCount {
                medianBin = i
                break
            }
        }
        
        // Convert median bin to value
        let imageRange = imageMaxValue - imageMinValue
        let binCenter = (Float(medianBin) + 0.5) / Float(numBins)
        let median = imageMinValue + binCenter * imageRange
        
        // Now calculate MAD using the median
        guard let madHistogramFunction = library.makeFunction(name: "build_mad_histogram") else {
            throw PipelineStepError.couldNotCreateResource("build_mad_histogram function")
        }
        
        guard let madHistogramPipelineState = try? device.makeComputePipelineState(function: madHistogramFunction) else {
            throw PipelineStepError.couldNotCreateResource("mad histogram compute pipeline state")
        }
        
        // Reset histogram for MAD
        for i in 0..<numBins {
            histogramPointer[i] = 0
        }
        
        // Create buffer for median value
        var medianVal = median
        guard let medianBuffer = device.makeBuffer(bytes: &medianVal, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("median buffer")
        }
        
        // Build MAD histogram
        guard let madCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }
        
        guard let madEncoder = madCommandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }
        
        madEncoder.setComputePipelineState(madHistogramPipelineState)
        madEncoder.setTexture(texture, index: 0)
        madEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        madEncoder.setBuffer(numBinsBuffer, offset: 0, index: 1)
        madEncoder.setBuffer(minBuffer, offset: 0, index: 2)
        madEncoder.setBuffer(maxBuffer, offset: 0, index: 3)
        madEncoder.setBuffer(medianBuffer, offset: 0, index: 4)
        
        madEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        madEncoder.endEncoding()
        
        madCommandBuffer.commit()
        madCommandBuffer.waitUntilCompleted()
        
        if let error = madCommandBuffer.error {
            throw PipelineStepError.executionFailed("GPU MAD histogram calculation failed: \(error.localizedDescription)")
        }
        
        // Find MAD from histogram
        cumulativeCount = 0
        var madBin = 0
        
        for i in 0..<numBins {
            cumulativeCount += Int(histogramPointer[i])
            if cumulativeCount >= targetCount {
                madBin = i
                break
            }
        }
        
        // Convert MAD bin to value
        let madBinCenter = (Float(madBin) + 0.5) / Float(numBins)
        let mad = madBinCenter * imageRange
        
        return (median, mad)
    }
    
    private func applyThreshold(
        texture: MTLTexture,
        threshold: Float,
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
        
        guard let function = library.makeFunction(name: "threshold") else {
            throw PipelineStepError.couldNotCreateResource("threshold function")
        }
        
        guard let pipelineState = try? device.makeComputePipelineState(function: function) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }
        
        // Create buffer for threshold value
        var thresholdValue = threshold
        guard let thresholdBuffer = device.makeBuffer(bytes: &thresholdValue, length: MemoryLayout<Float>.size, options: []) else {
            throw PipelineStepError.couldNotCreateResource("threshold buffer")
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
        encoder.setBuffer(thresholdBuffer, offset: 0, index: 0)
        
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
            throw PipelineStepError.executionFailed("GPU threshold failed: \(error.localizedDescription)")
        }
        
        return outputTexture
    }
}

