import Foundation
import Metal
import os

/// Processor for applying threshold to frames to create binary masks
public struct ThresholdProcessor: Processor {

    public var id: String { "threshold" }

    public init() {}

    /// Execute the threshold processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing "thresholded_frame" -> ProcessData (Frame, to be instantiated)
    ///   - parameters: Dictionary containing:
    ///     - "threshold_value" -> Parameter (Double, default: 3.0) - sigma multiplier for sigma method
    ///     - "method" -> Parameter (String, default: "sigma") - threshold method
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
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        // Get and validate parameters
        let (thresholdValue, method) = try extractParameters(from: parameters)

        Logger.processor.debug(
            "Applying threshold with method: \(method), threshold_value: \(thresholdValue)"
        )

        // Calculate actual threshold based on method
        let actualThreshold = try calculateThreshold(
            method: method,
            thresholdValue: thresholdValue,
            texture: inputTexture,
            device: device,
            commandQueue: commandQueue
        )

        // Apply threshold using Metal shader
        let outputTexture = try applyThresholdShader(
            inputTexture: inputTexture,
            threshold: actualThreshold,
            device: device,
            commandQueue: commandQueue
        )

        // Update output frame
        try ProcessorHelpers.updateOutputFrame(
            outputs: &outputs,
            outputName: "thresholded_frame",
            texture: outputTexture
        )

        Logger.processor.info("Threshold completed successfully (threshold: \(actualThreshold))")
    }

    /// Extract and validate parameters from the parameters dictionary
    private func extractParameters(
        from parameters: [String: Parameter]
    ) throws -> (thresholdValue: Double, method: String) {
        let thresholdValue: Double
        if let thresholdParam = parameters["threshold_value"] {
            if let doubleValue = thresholdParam.doubleValue {
                thresholdValue = doubleValue
            } else {
                throw ProcessorExecutionError.executionFailed("threshold_value parameter must be a number")
            }
        } else {
            thresholdValue = 3.0  // Default from YAML
        }

        let method: String
        if let methodParam = parameters["method"] {
            method = methodParam.stringValue
        } else {
            method = "sigma"  // Default from YAML
        }

        return (thresholdValue, method)
    }

    /// Calculate the actual threshold value based on the method
    private func calculateThreshold(
        method: String,
        thresholdValue: Double,
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Float {
        switch method {
        case "sigma":
            // Robust sigma: median + N × NMAD over the full image.
            // NMAD = 1.4826 × median(|xi − median(x)|), resistant to stars and galaxies.
            let (med, nmad) = try calculateMedianAndNMAD(
                texture: texture,
                device: device,
                commandQueue: commandQueue
            )
            let actualThreshold = med + Float(thresholdValue) * nmad
            Logger.processor.debug(
                "Calculated sigma threshold: \(actualThreshold) (median: \(med), NMAD: \(nmad))"
            )
            return actualThreshold
        case "fixed":
            let actualThreshold = Float(thresholdValue)
            Logger.processor.debug("Using fixed threshold: \(actualThreshold)")
            return actualThreshold
        default:
            throw ProcessorExecutionError.executionFailed("Unsupported threshold method: \(method)")
        }
    }

    /// Apply threshold shader to create binary mask
    private func applyThresholdShader(
        inputTexture: MTLTexture,
        threshold: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        // Load shader library and function
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let thresholdFunction = library.makeFunction(name: "threshold") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load threshold shader function")
        }

        // Create compute pipeline state
        let computePipelineState = try ProcessorHelpers.createComputePipelineState(
            function: thresholdFunction,
            device: device
        )

        // Create output texture (binary format: same as input)
        let outputDescriptor = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let outputTexture = try ProcessorHelpers.createTexture(
            descriptor: outputDescriptor,
            device: device
        )

        // Create buffer for threshold value
        var thresholdValueFloat = threshold
        let thresholdBuffer = try ProcessorHelpers.createBuffer(from: &thresholdValueFloat, device: device)

        // Create command buffer and encoder
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let computeEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        computeEncoder.setBuffer(thresholdBuffer, offset: 0, index: 0)

        // Calculate and dispatch threadgroups
        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()

        // Execute command buffer
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        return outputTexture
    }

    /// Computes the median and NMAD of the full texture using GPU histograms.
    ///
    /// Two-pass approach using `build_histogram` (pass 1) and `build_mad_histogram` (pass 2)
    /// from StatisticsShader.metal. Both kernels operate on the entire image so there is no
    /// spatial sampling bias. The NMAD (= 1.4826 × MAD) is robust against bright stars and
    /// galaxy residuals that would inflate a plain standard deviation.
    ///
    /// The input texture is expected to be normalised in [0, 1].
    private func calculateMedianAndNMAD(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> (median: Float, nmad: Float) {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let histFn = library.makeFunction(name: "build_histogram"),
              let madFn  = library.makeFunction(name: "build_mad_histogram") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load statistics shader functions (build_histogram / build_mad_histogram)"
            )
        }

        let histPipeline = try ProcessorHelpers.createComputePipelineState(function: histFn, device: device)
        let madPipeline  = try ProcessorHelpers.createComputePipelineState(function: madFn,  device: device)

        let numBins  = 8192
        var numBinsI = Int32(numBins)
        var minVal   = Float(0.0)
        var maxVal   = Float(1.0)

        let numBinsBuf = try ProcessorHelpers.createBuffer(from: &numBinsI, device: device)
        let minValBuf  = try ProcessorHelpers.createBuffer(from: &minVal,   device: device)
        let maxValBuf  = try ProcessorHelpers.createBuffer(from: &maxVal,   device: device)

        let totalPixels = texture.width * texture.height
        let halfPixels  = totalPixels / 2

        // --- Pass 1: pixel histogram → median ---
        guard let histBuf = device.makeBuffer(
            length: numBins * MemoryLayout<Int32>.size, options: .storageModeShared
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create histogram buffer")
        }
        memset(histBuf.contents(), 0, histBuf.length)

        let cb1  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc1 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb1)
        enc1.setComputePipelineState(histPipeline)
        enc1.setTexture(texture, index: 0)
        enc1.setBuffer(histBuf,    offset: 0, index: 0)
        enc1.setBuffer(numBinsBuf, offset: 0, index: 1)
        enc1.setBuffer(minValBuf,  offset: 0, index: 2)
        enc1.setBuffer(maxValBuf,  offset: 0, index: 3)
        let (tgSize, tgGrid) = ProcessorHelpers.calculateThreadgroups(for: texture)
        enc1.dispatchThreadgroups(tgGrid, threadsPerThreadgroup: tgSize)
        enc1.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb1)

        let histPtr = histBuf.contents().bindMemory(to: Int32.self, capacity: numBins)
        var cumul   = 0
        var medBin  = numBins / 2
        for i in 0..<numBins {
            cumul += Int(histPtr[i])
            if cumul >= halfPixels { medBin = i; break }
        }
        let median = (Float(medBin) + 0.5) / Float(numBins)   // imageMin=0, imageRange=1

        // --- Pass 2: |xi − median| histogram → MAD ---
        guard let madBuf = device.makeBuffer(
            length: numBins * MemoryLayout<Int32>.size, options: .storageModeShared
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create MAD histogram buffer")
        }
        memset(madBuf.contents(), 0, madBuf.length)

        var medianF   = median
        let medianBuf = try ProcessorHelpers.createBuffer(from: &medianF, device: device)

        let cb2  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc2 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb2)
        enc2.setComputePipelineState(madPipeline)
        enc2.setTexture(texture, index: 0)
        enc2.setBuffer(madBuf,     offset: 0, index: 0)
        enc2.setBuffer(numBinsBuf, offset: 0, index: 1)
        enc2.setBuffer(minValBuf,  offset: 0, index: 2)
        enc2.setBuffer(maxValBuf,  offset: 0, index: 3)
        enc2.setBuffer(medianBuf,  offset: 0, index: 4)
        enc2.dispatchThreadgroups(tgGrid, threadsPerThreadgroup: tgSize)
        enc2.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb2)

        let madPtr = madBuf.contents().bindMemory(to: Int32.self, capacity: numBins)
        cumul = 0
        var madBin = numBins / 2
        for i in 0..<numBins {
            cumul += Int(madPtr[i])
            if cumul >= halfPixels { madBin = i; break }
        }
        // absdev is mapped over [0, imageRange=1.0]
        let mad  = (Float(madBin) + 0.5) / Float(numBins)
        let nmad = 1.4826 * mad

        return (median, nmad)
    }
}
