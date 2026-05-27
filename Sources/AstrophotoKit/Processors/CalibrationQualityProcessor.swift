import Foundation
import Metal
import TabularData
import os

/// Computes quality metrics for calibration frames (bias, dark, flat).
///
/// Pixel statistics are estimated from a spatially-representative subsample of the
/// frame (every `sample_step` pixels in each dimension). The processor measures:
///
/// - **Mean level** — average pixel value; the bias pedestal for bias frames, the
///   dark current level for dark frames, or the illumination level for flats.
/// - **Noise sigma** — standard deviation of pixel values; readout noise for bias
///   frames, combined readout+thermal noise for darks.
/// - **Hot pixel count** — approximate number of pixels whose value exceeds
///   `mean + hot_pixel_sigma × sigma`. High hot-pixel counts on a dark frame
///   indicate a sensor with elevated defect rates.
///
/// When the input frame carries FITS scale information (`fitsMinValue` / `fitsMaxValue`)
/// all values are also expressed in ADU.
///
/// **Input**
/// - `input_frame` (Frame) — the calibration frame to analyse.
///
/// **Parameters**
/// | Name               | Type   | Default | Description                                   |
/// |--------------------|--------|---------|-----------------------------------------------|
/// | hot_pixel_sigma    | Double | 5.0     | Sigma threshold above mean for hot pixels.    |
/// | sample_step        | Int    | 4       | Subsampling stride (1 = full frame).          |
///
/// **Output**
/// - `calibration_quality` (TableData) — single-row table.
///
/// **Output columns**
/// | Column                    | Type   | Description                                          |
/// |---------------------------|--------|------------------------------------------------------|
/// | mean_level                | Double | Mean pixel value, normalised 0–1.                   |
/// | noise_sigma               | Double | Pixel std-dev, normalised 0–1.                      |
/// | hot_pixel_count           | Int    | Estimated hot pixel count (scaled to full frame).   |
/// | hot_pixel_sigma_threshold | Double | Sigma threshold used for hot pixel detection.       |
/// | mean_level_adu            | Double | Mean level in ADU (when FITS scale info available). |
/// | noise_sigma_adu           | Double | Noise sigma in ADU (scale only, no offset).         |
public struct CalibrationQualityProcessor: Processor {

    public var id: String { "calibration_quality" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (inputFrame, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        let hotPixelSigma = parameters["hot_pixel_sigma"]?.doubleValue ?? 5.0
        let sampleStep    = max(1, parameters["sample_step"]?.intValue ?? 4)

        let w = inputTexture.width, h = inputTexture.height
        Logger.processor.debug(
            "CalibrationQualityProcessor: \(w)×\(h) sample_step=\(sampleStep), hot_pixel_sigma=\(hotPixelSigma)"
        )

        // Sample pixels from the texture into CPU memory.
        let pixels = try samplePixels(
            texture: inputTexture,
            step: sampleStep,
            device: device,
            commandQueue: commandQueue
        )

        guard !pixels.isEmpty else {
            throw ProcessorExecutionError.executionFailed(
                "CalibrationQualityProcessor: no pixels sampled from frame"
            )
        }

        // Compute mean and sigma.
        let n = Double(pixels.count)
        let mean = pixels.reduce(0.0, +) / n
        let variance = pixels.map { ($0 - mean) * ($0 - mean) }.reduce(0.0, +) / n
        let sigma = sqrt(max(0.0, variance))

        // Count hot pixels (value > mean + N·sigma), then scale to the full frame.
        let threshold = mean + hotPixelSigma * sigma
        let hotInSample = pixels.filter { $0 > threshold }.count
        // The blit copies the top-left sampleW × sampleH region; each sample pixel
        // represents step × step pixels of the original image.
        let hotPixelCount = hotInSample * sampleStep * sampleStep

        // ADU conversion — sigma uses scale only (no offset since it's a difference).
        let meanADU:  Double? = inputFrame.toADU(mean)
        let sigmaADU: Double? = {
            guard let minVal = inputFrame.fitsMinValue,
                  let maxVal = inputFrame.fitsMaxValue,
                  maxVal > minVal else { return nil }
            return sigma * (maxVal - minVal)
        }()

        let meanStr  = String(format: "%.4f", mean)
        let sigmaStr = String(format: "%.4f", sigma)
        let aduInfo  = meanADU.map { String(format: " (%.1f ADU)", $0) } ?? ""
        let sigmaAduInfo = sigmaADU.map { String(format: " (%.2f ADU)", $0) } ?? ""
        Logger.processor.info(
            "CalibrationQualityProcessor: mean=\(meanStr)\(aduInfo), sigma=\(sigmaStr)\(sigmaAduInfo), hot_pixels≈\(hotPixelCount)"
        )

        // Write output table.
        guard var table = outputs["calibration_quality"] as? TableData else { return }
        var df = DataFrame()
        df.append(column: Column(name: "mean_level",                contents: [mean]))
        df.append(column: Column(name: "noise_sigma",               contents: [sigma]))
        df.append(column: Column(name: "hot_pixel_count",           contents: [hotPixelCount]))
        df.append(column: Column(name: "hot_pixel_sigma_threshold", contents: [hotPixelSigma]))
        if let v = meanADU  { df.append(column: Column(name: "mean_level_adu",  contents: [v])) }
        if let v = sigmaADU { df.append(column: Column(name: "noise_sigma_adu", contents: [v])) }
        table.dataFrame = df
        outputs["calibration_quality"] = table
    }

    // MARK: - Pixel sampling

    /// Copies the top-left `texture.width/step × texture.height/step` region of the
    /// texture into a CPU-accessible buffer using a Metal blit encoder.
    /// Returns a flat array of normalised [0, 1] float values.
    private func samplePixels(
        texture: MTLTexture,
        step: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [Double] {
        let sampleW    = max(1, texture.width  / step)
        let sampleH    = max(1, texture.height / step)
        let bytesPerRow = sampleW * MemoryLayout<Float32>.size
        let bufferSize  = bytesPerRow * sampleH

        guard let readBuffer = device.makeBuffer(
            length: bufferSize, options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "CalibrationQualityProcessor: cannot create pixel read buffer"
            )
        }

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "CalibrationQualityProcessor: cannot create blit encoder"
            )
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sampleW, height: sampleH, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        let ptr = readBuffer.contents().bindMemory(
            to: Float32.self, capacity: sampleW * sampleH
        )
        return Array(UnsafeBufferPointer(start: ptr, count: sampleW * sampleH))
            .map { Double($0) }
    }
}
