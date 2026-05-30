import Foundation
import Metal
import os
import TabularData

/// Processor for estimating and subtracting background from frames
public struct BackgroundEstimationProcessor: Processor {

    public var id: String { "background_estimation" }

    public init() {}

    /// Execute the background estimation processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing:
    ///     - "background_frame" -> ProcessData (Frame, to be instantiated)
    ///     - "background_subtracted_frame" -> ProcessData (Frame, to be instantiated)
    ///     - "background_level" -> ProcessData (TableData, to be instantiated).
    ///       Contains `background_level` (normalised 0–1) and, when the input frame
    ///       carries FITS scale info, `background_level_adu` (in ADU).
    ///   - parameters: Dictionary (empty for this processor)
    ///   - device: Metal device for GPU operations
    ///   - commandQueue: Metal command queue for GPU operations
    /// - Throws: ProcessorExecutionError if execution fails
    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Validate input frame
        let (inputFrame, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        Logger.processor.debug(
            "Estimating background (width: \(inputTexture.width), height: \(inputTexture.height))"
        )

        // Get window size parameter (default: 50 to handle larger stars)
        // Note: The window should be larger than the largest stars in the image
        // A 50x50 window means 2500 reads per pixel, which is slower but more accurate
        // For images with smaller stars, you can reduce this to improve performance
        let windowSize: Int32
        if let windowSizeParam = parameters["window_size"] {
            if let intValue = windowSizeParam.intValue {
                windowSize = Int32(intValue)
            } else if let doubleValue = windowSizeParam.doubleValue {
                windowSize = Int32(doubleValue)
            } else {
                throw ProcessorExecutionError.executionFailed("window_size parameter must be a number")
            }
        } else {
            windowSize = 50  // Default: large enough to handle typical star sizes
        }

        Logger.processor.debug("Using window size: \(windowSize)x\(windowSize)")

        // Get histogram bins parameter (default: 128 for good performance/accuracy balance)
        let numBins: Int32
        if let numBinsParam = parameters["histogram_bins"] {
            if let intValue = numBinsParam.intValue {
                numBins = Int32(intValue)
            } else if let doubleValue = numBinsParam.doubleValue {
                numBins = Int32(doubleValue)
            } else {
                throw ProcessorExecutionError.executionFailed("histogram_bins parameter must be a number")
            }
        } else {
            numBins = 128  // Default: good balance between performance and accuracy
        }

        // Get sample step threshold parameter (default: 30 - windows larger than this will sample every 2nd pixel)
        let sampleStepThreshold: Int32
        if let thresholdParam = parameters["sample_step_threshold"] {
            if let intValue = thresholdParam.intValue {
                sampleStepThreshold = Int32(intValue)
            } else if let doubleValue = thresholdParam.doubleValue {
                sampleStepThreshold = Int32(doubleValue)
            } else {
                throw ProcessorExecutionError.executionFailed("sample_step_threshold parameter must be a number")
            }
        } else {
            sampleStepThreshold = 30  // Default: sample every 2nd pixel for windows > 30
        }

        Logger.processor.debug("Using histogram bins: \(numBins), sample step threshold: \(sampleStepThreshold)")

        // Load shader library and functions
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let localMedianFunction = library.makeFunction(name: "local_median"),
              let localMedianSubtractFunction = library.makeFunction(name: "local_median_subtract") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load background estimation shader functions"
            )
        }

        // Create compute pipeline states
        let localMedianPipelineState = try ProcessorHelpers.createComputePipelineState(
            function: localMedianFunction,
            device: device
        )
        let localMedianSubtractPipelineState = try ProcessorHelpers.createComputePipelineState(
            function: localMedianSubtractFunction,
            device: device
        )

        // Image value range (assuming normalized [0, 1] for now)
        let imageMinValue: Float = 0.0
        let imageMaxValue: Float = 1.0

        // Create textures
        let backgroundDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let backgroundTexture = try ProcessorHelpers.createTexture(
            descriptor: backgroundDescriptor,
            device: device
        )

        // Two intermediate textures for ping-pong buffering across multi-pass runs —
        // reading and writing the same texture in one Metal dispatch is undefined behaviour.
        let intermediateDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let intermediateTextureA = try ProcessorHelpers.createTexture(
            descriptor: intermediateDescriptor,
            device: device
        )
        let intermediateTextureB = try ProcessorHelpers.createTexture(
            descriptor: intermediateDescriptor,
            device: device
        )

        let subtractedDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let subtractedTexture = try ProcessorHelpers.createTexture(
            descriptor: subtractedDescriptor,
            device: device
        )

        // Create parameter buffers (will be updated for each pass)
        var minValue = imageMinValue
        var maxValue = imageMaxValue
        var numBinsInt = numBins
        var sampleStepThresholdInt = sampleStepThreshold
        let minValueBuffer = try ProcessorHelpers.createBuffer(from: &minValue, device: device)
        let maxValueBuffer = try ProcessorHelpers.createBuffer(from: &maxValue, device: device)
        let numBinsBuffer = try ProcessorHelpers.createBuffer(from: &numBinsInt, device: device)
        let sampleStepThresholdBuffer = try ProcessorHelpers.createBuffer(from: &sampleStepThresholdInt, device: device)

        // Multi-pass approach: progressively larger windows
        let multiPassParams = MultiPassParams(
            inputTexture: inputTexture,
            backgroundTexture: backgroundTexture,
            intermediateTextureA: intermediateTextureA,
            intermediateTextureB: intermediateTextureB,
            windowSize: Int(windowSize),
            localMedianPipelineState: localMedianPipelineState,
            minValueBuffer: minValueBuffer,
            maxValueBuffer: maxValueBuffer,
            numBinsBuffer: numBinsBuffer,
            sampleStepThresholdBuffer: sampleStepThresholdBuffer,
            device: device,
            commandQueue: commandQueue
        )
        try performMultiPassBackgroundEstimation(params: multiPassParams)

        // Final step: Subtract background from input
        try subtractBackgroundFromInput(
            inputTexture: inputTexture,
            backgroundTexture: backgroundTexture,
            subtractedTexture: subtractedTexture,
            localMedianSubtractPipelineState: localMedianSubtractPipelineState,
            minValueBuffer: minValueBuffer,
            maxValueBuffer: maxValueBuffer,
            commandQueue: commandQueue
        )

        // Calculate average background level and update outputs
        try finalizeOutputs(
            inputFrame: inputFrame,
            backgroundTexture: backgroundTexture,
            subtractedTexture: subtractedTexture,
            outputs: &outputs,
            device: device,
            commandQueue: commandQueue
        )
    }

    /// Calculate average background level from background texture
    /// - Parameters:
    ///   - texture: The background texture
    ///   - device: Metal device
    ///   - commandQueue: Metal command queue
    /// - Returns: Average background level
    /// - Throws: ProcessorExecutionError if calculation fails
    private func calculateAverageBackgroundLevel(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Double {
        // Sample a subset of pixels for performance (every 10th pixel)
        let sampleRate = 10
        let width = texture.width
        let height = texture.height
        let sampleWidth = max(1, width / sampleRate)
        let sampleHeight = max(1, height / sampleRate)
        let bytesPerRow = sampleWidth * MemoryLayout<Float32>.size
        let bufferSize = bytesPerRow * sampleHeight

        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create read buffer")
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create command buffer")
        }

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create blit encoder")
        }

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

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        // Calculate average from sample
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: sampleWidth * sampleHeight)
        let pixels = Array(UnsafeBufferPointer(start: pixelPointer, count: sampleWidth * sampleHeight))
        let average = pixels.reduce(0.0, +) / Float(pixels.count)

        return Double(average)
    }

    /// Parameters for multi-pass background estimation
    private struct MultiPassParams {
        let inputTexture: MTLTexture
        let backgroundTexture: MTLTexture
        let intermediateTextureA: MTLTexture
        let intermediateTextureB: MTLTexture
        let windowSize: Int
        let localMedianPipelineState: MTLComputePipelineState
        let minValueBuffer: MTLBuffer
        let maxValueBuffer: MTLBuffer
        let numBinsBuffer: MTLBuffer
        let sampleStepThresholdBuffer: MTLBuffer
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
    }

    /// Perform multi-pass background estimation with progressively larger windows
    /// - Parameter params: Multi-pass parameters
    /// - Throws: ProcessorExecutionError if execution fails
    private func performMultiPassBackgroundEstimation(params: MultiPassParams) throws {
        // Start with small window and increase to target size
        let windowSizes = calculateProgressiveWindowSizes(targetSize: params.windowSize)
        Logger.processor.debug("Using multi-pass approach with window sizes: \(windowSizes)")

        // Calculate threadgroups
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: params.inputTexture)

        // Multi-pass background estimation.
        // Ping-pong between intermediateTextureA and intermediateTextureB so that no
        // pass reads and writes the same texture — Metal does not permit that.
        for (passIndex, passWindowSize) in windowSizes.enumerated() {
            var windowSizeInt = Int32(passWindowSize)
            let windowSizeBuffer = try ProcessorHelpers.createBuffer(from: &windowSizeInt, device: params.device)

            // Create command buffer for this pass
            let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: params.commandQueue)

            // Determine input and output textures for this pass.
            // Pass 0: inputTexture → A
            // Pass 1: A → B (or backgroundTexture if last)
            // Pass 2: B → A (or backgroundTexture if last)
            // ...
            let passInputTexture: MTLTexture
            let passOutputTexture: MTLTexture
            if passIndex == 0 {
                passInputTexture  = params.inputTexture
                passOutputTexture = windowSizes.count == 1 ? params.backgroundTexture : params.intermediateTextureA
            } else {
                let readA = passIndex % 2 == 1
                passInputTexture  = readA ? params.intermediateTextureA : params.intermediateTextureB
                passOutputTexture = passIndex == windowSizes.count - 1
                    ? params.backgroundTexture
                    : (readA ? params.intermediateTextureB : params.intermediateTextureA)
            }

            // Estimate local median background with current window size
            let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)
            encoder.setComputePipelineState(params.localMedianPipelineState)
            encoder.setTexture(passInputTexture, index: 0)
            encoder.setTexture(passOutputTexture, index: 1)
            encoder.setBuffer(windowSizeBuffer, offset: 0, index: 0)
            encoder.setBuffer(params.minValueBuffer, offset: 0, index: 1)
            encoder.setBuffer(params.maxValueBuffer, offset: 0, index: 2)
            encoder.setBuffer(params.numBinsBuffer, offset: 0, index: 3)
            encoder.setBuffer(params.sampleStepThresholdBuffer, offset: 0, index: 4)
            encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            // Execute this pass
            try ProcessorHelpers.executeCommandBuffer(commandBuffer)

            Logger.processor.debug(
                "Completed pass \(passIndex + 1)/\(windowSizes.count) with window size \(passWindowSize)"
            )
        }
    }

    /// Subtract background from input texture
    /// - Parameters:
    ///   - inputTexture: The input texture
    ///   - backgroundTexture: The background texture
    ///   - subtractedTexture: The output texture for background-subtracted result
    ///   - localMedianSubtractPipelineState: The compute pipeline state
    ///   - minValueBuffer: Buffer for minimum image value
    ///   - maxValueBuffer: Buffer for maximum image value
    ///   - commandQueue: Metal command queue
    /// - Throws: ProcessorExecutionError if execution fails
    private func subtractBackgroundFromInput(
        inputTexture: MTLTexture,
        backgroundTexture: MTLTexture,
        subtractedTexture: MTLTexture,
        localMedianSubtractPipelineState: MTLComputePipelineState,
        minValueBuffer: MTLBuffer,
        maxValueBuffer: MTLBuffer,
        commandQueue: MTLCommandQueue
    ) throws {
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)
        encoder.setComputePipelineState(localMedianSubtractPipelineState)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(backgroundTexture, index: 1)
        encoder.setTexture(subtractedTexture, index: 2)
        encoder.setBuffer(minValueBuffer, offset: 0, index: 0)
        encoder.setBuffer(maxValueBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
    }

    /// Finalize outputs by calculating background level and updating output frames.
    /// Writes `background_level` (normalised 0–1) and, when FITS scale information
    /// is available on `inputFrame`, also writes `background_level_adu` in ADU.
    /// - Parameters:
    ///   - inputFrame: The original input frame (for FITS scale info).
    ///   - backgroundTexture: The background texture
    ///   - subtractedTexture: The background-subtracted texture
    ///   - outputs: Dictionary of processor outputs (inout)
    ///   - device: Metal device
    ///   - commandQueue: Metal command queue
    /// - Throws: ProcessorExecutionError if execution fails
    private func finalizeOutputs(
        inputFrame: Frame,
        backgroundTexture: MTLTexture,
        subtractedTexture: MTLTexture,
        outputs: inout [String: ProcessData],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Calculate average background level for table output
        let backgroundLevel = try calculateAverageBackgroundLevel(
            texture: backgroundTexture,
            device: device,
            commandQueue: commandQueue
        )

        // Update output frames
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "background_frame",
            texture: backgroundTexture
        )

        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "background_subtracted_frame",
            texture: subtractedTexture
        )

        // Compute NMAD of the background-subtracted frame as a robust noise sigma estimate.
        // Stars are positive outliers that the NMAD naturally suppresses.
        let noiseSigma = (try? calculateNoiseSigma(
            texture: subtractedTexture,
            device: device,
            commandQueue: commandQueue
        )) ?? 0.0

        // Create table with background level and noise statistics
        if var backgroundLevelTable = outputs["background_level"] as? TableData {
            var dataFrame = DataFrame()
            dataFrame.append(column: Column(name: "background_level",       contents: [backgroundLevel]))
            dataFrame.append(column: Column(name: "background_noise_sigma", contents: [noiseSigma]))
            if let fitsMin = inputFrame.fitsMinValue, let fitsMax = inputFrame.fitsMaxValue {
                let scale = fitsMax - fitsMin
                dataFrame.append(column: Column(name: "background_level_adu",       contents: [backgroundLevel * scale + fitsMin]))
                dataFrame.append(column: Column(name: "background_noise_sigma_adu", contents: [noiseSigma * scale]))
            }
            backgroundLevelTable.dataFrame = dataFrame
            outputs["background_level"] = backgroundLevelTable
        }

        let aduInfo = inputFrame.toADU(backgroundLevel).map { String(format: " (%.1f ADU)", $0) } ?? ""
        let sigmaInfo: String = {
            guard let fitsMin = inputFrame.fitsMinValue, let fitsMax = inputFrame.fitsMaxValue else { return "" }
            return String(format: ", σ=%.2f ADU", noiseSigma * (fitsMax - fitsMin))
        }()
        Logger.processor.info("Background estimation completed (level: \(backgroundLevel)\(aduInfo)\(sigmaInfo)")
    }

    /// Compute NMAD (Normalised Median Absolute Deviation) of the background-subtracted
    /// texture as a robust per-pixel noise sigma estimate.  Stars produce large positive
    /// outliers that the median-based statistic naturally suppresses.
    ///
    /// Formula: σ_NMAD = 1.4826 × median(|xi − median(x)|)
    /// The 1.4826 factor makes NMAD consistent with the Gaussian σ.
    private func calculateNoiseSigma(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Double {
        let sampleRate = 10
        let width  = texture.width
        let height = texture.height
        let sampleWidth  = max(1, width  / sampleRate)
        let sampleHeight = max(1, height / sampleRate)
        let bytesPerRow = sampleWidth * MemoryLayout<Float32>.size
        let bufferSize  = bytesPerRow * sampleHeight

        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create noise-sigma read buffer")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder   = commandBuffer.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create command buffer for noise sigma")
        }
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sampleWidth, height: sampleHeight, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        let ptr    = readBuffer.contents().bindMemory(to: Float32.self, capacity: sampleWidth * sampleHeight)
        var pixels = Array(UnsafeBufferPointer(start: ptr, count: sampleWidth * sampleHeight))
            .map { Double($0) }
        guard !pixels.isEmpty else { return 0 }

        pixels.sort()
        let med = pixels.count % 2 == 0
            ? (pixels[pixels.count / 2 - 1] + pixels[pixels.count / 2]) / 2.0
            : pixels[pixels.count / 2]

        var absDevs = pixels.map { abs($0 - med) }
        absDevs.sort()
        let medAbsDev = absDevs.count % 2 == 0
            ? (absDevs[absDevs.count / 2 - 1] + absDevs[absDevs.count / 2]) / 2.0
            : absDevs[absDevs.count / 2]

        return 1.4826 * medAbsDev
    }

    /// Calculate progressive window sizes for multi-pass approach
    /// Starts with a small window and progressively increases to target size
    /// - Parameter targetSize: The final target window size
    /// - Returns: Array of window sizes to use in each pass
    private func calculateProgressiveWindowSizes(targetSize: Int) -> [Int] {
        // Start with a small window (10x10 is fast and gives good initial estimate)
        let startSize = 10

        // If target is small, just use single pass
        if targetSize <= startSize {
            return [targetSize]
        }

        // Build progressive sizes: 10 -> 20 -> 40 -> 50 (or closest)
        var sizes: [Int] = [startSize]
        var currentSize = startSize

        while currentSize < targetSize {
            // Double the size each time, but don't exceed target
            let nextSize = min(currentSize * 2, targetSize)
            if nextSize > currentSize {
                sizes.append(nextSize)
                currentSize = nextSize
            } else {
                break
            }
        }

        // Ensure we end with the exact target size
        if sizes.last != targetSize {
            sizes.append(targetSize)
        }

        return sizes
    }
}


