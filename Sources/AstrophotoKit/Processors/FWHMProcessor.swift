import Foundation
import Metal
import TabularData
import os

/// Structure to represent FWHM measurements for a star
private struct FWHMMeasurements {
    let fwhmMajor: Double  // FWHM along major axis
    let fwhmMinor: Double  // FWHM along minor axis
    let eccentricity: Double  // 0 = circular, 1 = fully elongated
}

/// Processor for calculating Full Width at Half Maximum (FWHM) for detected stars
/// Uses image moments on the original (non-binary) image to determine star profiles
public struct FWHMProcessor: Processor {

    public var id: String { "fwhm" }

    public init() {}

    /// Execute the FWHM processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame) and "pixel_coordinates" -> ProcessData (TableData)
    ///   - outputs: Dictionary containing "pixel_coordinates" -> ProcessData (TableData, to be updated with FWHM values)
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
        // Validate inputs
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)
        let dataFrame = try validateAndGetDataFrame(from: inputs)

        Logger.processor.debug("Calculating FWHM for \(dataFrame.rows.count) stars")

        // Extract star info with region sizes based on axes
        let starInfoArray = try extractStarInfoWithRegionSizes(from: dataFrame)

        // Calculate moments using GPU shader
        let moments = try calculateMomentsGPU(
            texture: inputTexture,
            starInfo: starInfoArray,
            device: device,
            commandQueue: commandQueue
        )

        // Process moments to get FWHM, flux, centroids, and saturation
        let starProperties = processMoments(moments: moments)

        // Calculate statistics (median and σ-clipped mean), excluding saturated stars
        let statistics = calculateFWHMStatistics(
            fwhmMajor: starProperties.fwhmMajor,
            fwhmMinor: starProperties.fwhmMinor,
            saturated: starProperties.saturated
        )

        logFWHMResults(statistics: statistics)

        // Update output tables
        try updateOutputTable(
            outputs: &outputs,
            dataFrame: dataFrame,
            starProperties: starProperties
        )

        try updateMedianFWHMTable(
            outputs: &outputs,
            statistics: statistics
        )
    }

    // MARK: - Private Helper Methods

    /// Structure to hold star properties calculated from moments
    private struct StarProperties {
        let fwhmMajor: [Double]
        let fwhmMinor: [Double]
        let eccentricity: [Double]
        let flux: [Double]
        let centroidX: [Double]
        let centroidY: [Double]
        let saturated: [Bool]
    }

    /// Structure to hold FWHM statistics
    private struct FWHMStatistics {
        let medianMajor: Double
        let medianMinor: Double
        let sigmaClippedMeanMajor: Double
        let sigmaClippedMeanMinor: Double
    }

    /// Validates inputs and extracts the DataFrame
    private func validateAndGetDataFrame(from inputs: [String: ProcessData]) throws -> DataFrame {
        guard let inputTable = inputs["pixel_coordinates"] as? TableData,
              let dataFrame = inputTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("pixel_coordinates")
        }
        return dataFrame
    }

    /// Extracts star information and calculates region sizes based on major/minor axes
    private func extractStarInfoWithRegionSizes(from dataFrame: DataFrame) throws -> [(centroidX: Double, centroidY: Double, regionSize: Int)] {
        guard let centroidXColumn = dataFrame.columns.first(where: { $0.name == "centroid_x" }),
              let centroidYColumn = dataFrame.columns.first(where: { $0.name == "centroid_y" }),
              let majorAxisColumn = dataFrame.columns.first(where: { $0.name == "major_axis" }),
              let minorAxisColumn = dataFrame.columns.first(where: { $0.name == "minor_axis" }) else {
            throw ProcessorExecutionError.executionFailed(
                "Missing required columns (centroid_x, centroid_y, major_axis, minor_axis) in pixel_coordinates table"
            )
        }

        var starInfoArray: [(centroidX: Double, centroidY: Double, regionSize: Int)] = []
        starInfoArray.reserveCapacity(dataFrame.rows.count)

        // Multiplier to ensure we capture enough of the star (including wings)
        // Using 4x the major axis to ensure we capture the full profile
        let regionSizeMultiplier: Double = 4.0
        let minRegionSize = 15  // Minimum region size for very small stars
        let maxRegionSize = 200  // Maximum region size to avoid excessive computation

        for rowIndex in 0..<dataFrame.rows.count {
            guard let centroidX = centroidXColumn[rowIndex] as? Double,
                  let centroidY = centroidYColumn[rowIndex] as? Double,
                  let majorAxis = majorAxisColumn[rowIndex] as? Double,
                  let minorAxis = minorAxisColumn[rowIndex] as? Double else {
                // Use default region size if axes are missing
                starInfoArray.append((centroidX: 0.0, centroidY: 0.0, regionSize: 30))
                continue
            }

            // Calculate region size based on the larger of major or minor axis
            // Round up to nearest odd number (for symmetric half-size calculation)
            let axisSize = max(majorAxis, minorAxis)
            var calculatedSize = Int(ceil(axisSize * regionSizeMultiplier))
            calculatedSize = max(minRegionSize, min(calculatedSize, maxRegionSize))
            // Make it odd for symmetric half-size calculation
            if calculatedSize % 2 == 0 {
                calculatedSize += 1
            }

            starInfoArray.append((centroidX: centroidX, centroidY: centroidY, regionSize: calculatedSize))
        }

        return starInfoArray
    }

    /// Processes moments to calculate FWHM, flux, centroids, and saturation
    private func processMoments(moments: [GPUMomentResults]) -> StarProperties {
        var fwhmMajorValues: [Double] = []
        var fwhmMinorValues: [Double] = []
        var eccentricityValues: [Double] = []
        var fluxValues: [Double] = []
        var updatedCentroidXValues: [Double] = []
        var updatedCentroidYValues: [Double] = []
        var saturatedValues: [Bool] = []
        fwhmMajorValues.reserveCapacity(moments.count)
        fwhmMinorValues.reserveCapacity(moments.count)
        eccentricityValues.reserveCapacity(moments.count)
        fluxValues.reserveCapacity(moments.count)
        updatedCentroidXValues.reserveCapacity(moments.count)
        updatedCentroidYValues.reserveCapacity(moments.count)
        saturatedValues.reserveCapacity(moments.count)

        // Saturation threshold: pixels normalized to 0-1, so 0.9 indicates near saturation
        // Using 0.9 (90%) is more conservative and flags stars approaching saturation
        // This helps exclude stars that may have photometry issues even if not fully saturated
        let saturationThreshold: Double = 0.9

        for moment in moments {
            let fwhm = calculateFWHMFromMoments(moment: moment)
            fwhmMajorValues.append(fwhm.fwhmMajor)
            fwhmMinorValues.append(fwhm.fwhmMinor)
            eccentricityValues.append(fwhm.eccentricity)

            // Flux is the zeroth moment (total weighted intensity)
            fluxValues.append(moment.m00)

            // Updated centroids from first moments
            if moment.m00 > 0 {
                updatedCentroidXValues.append(moment.m10 / moment.m00)
                updatedCentroidYValues.append(moment.m01 / moment.m00)
            } else {
                updatedCentroidXValues.append(0.0)
                updatedCentroidYValues.append(0.0)
            }

            // Detect saturation: if maximum pixel value in region is at or above threshold
            saturatedValues.append(moment.maxPixelValue >= saturationThreshold)
        }

        return StarProperties(
            fwhmMajor: fwhmMajorValues,
            fwhmMinor: fwhmMinorValues,
            eccentricity: eccentricityValues,
            flux: fluxValues,
            centroidX: updatedCentroidXValues,
            centroidY: updatedCentroidYValues,
            saturated: saturatedValues
        )
    }

    /// Calculates FWHM statistics (median and σ-clipped mean), excluding saturated stars
    private func calculateFWHMStatistics(
        fwhmMajor: [Double],
        fwhmMinor: [Double],
        saturated: [Bool]
    ) -> FWHMStatistics {
        // Filter out saturated stars and stars with invalid FWHM (<= 0)
        var validFWHMMajor: [Double] = []
        var validFWHMMinor: [Double] = []
        validFWHMMajor.reserveCapacity(fwhmMajor.count)
        validFWHMMinor.reserveCapacity(fwhmMinor.count)

        for index in 0..<fwhmMajor.count {
            // Only include non-saturated stars with valid FWHM values
            if !saturated[index] && fwhmMajor[index] > 0 {
                validFWHMMajor.append(fwhmMajor[index])
            }
            if !saturated[index] && fwhmMinor[index] > 0 {
                validFWHMMinor.append(fwhmMinor[index])
            }
        }

        let medianMajor = validFWHMMajor.isEmpty ? 0.0 : calculateMedian(validFWHMMajor)
        let medianMinor = validFWHMMinor.isEmpty ? 0.0 : calculateMedian(validFWHMMinor)

        // Calculate σ-clipped mean FWHM
        let sigmaClippedMeanMajor = validFWHMMajor.isEmpty ? 0.0 : calculateSigmaClippedMean(validFWHMMajor)
        let sigmaClippedMeanMinor = validFWHMMinor.isEmpty ? 0.0 : calculateSigmaClippedMean(validFWHMMinor)

        return FWHMStatistics(
            medianMajor: medianMajor,
            medianMinor: medianMinor,
            sigmaClippedMeanMajor: sigmaClippedMeanMajor,
            sigmaClippedMeanMinor: sigmaClippedMeanMinor
        )
    }

    /// Logs FWHM calculation results
    private func logFWHMResults(statistics: FWHMStatistics) {
        let logMessage = String(
            format: "FWHM calculation completed. Median FWHM (major): %.3f, " +
            "Median FWHM (minor): %.3f, σ-clipped mean FWHM (major): %.3f, " +
            "σ-clipped mean FWHM (minor): %.3f",
            statistics.medianMajor, statistics.medianMinor,
            statistics.sigmaClippedMeanMajor, statistics.sigmaClippedMeanMinor
        )
        Logger.processor.info("\(logMessage)")
    }

    /// Updates the output table with reordered columns
    private func updateOutputTable(
        outputs: inout [String: ProcessData],
        dataFrame: DataFrame,
        starProperties: StarProperties
    ) throws {
        guard var outputTable = outputs["pixel_coordinates"] as? TableData else {
            return
        }

        // Rebuild DataFrame with columns in desired order
        var reorderedDataFrame = DataFrame()

        // Add id column
        if let idColumn = dataFrame.columns.first(where: { $0.name == "id" }) {
            let idValues: [Int] = (0..<dataFrame.rows.count).compactMap { idColumn[$0] as? Int }
            reorderedDataFrame.append(column: Column(name: "id", contents: idValues))
        }

        // Add area column
        if let areaColumn = dataFrame.columns.first(where: { $0.name == "area" }) {
            let areaValues: [Int] = (0..<dataFrame.rows.count).compactMap { areaColumn[$0] as? Int }
            reorderedDataFrame.append(column: Column(name: "area", contents: areaValues))
        }

        // Add flux column (new/updated)
        reorderedDataFrame.append(column: Column(name: "flux", contents: starProperties.flux))

        // Add updated centroid columns
        reorderedDataFrame.append(column: Column(name: "centroid_x", contents: starProperties.centroidX))
        reorderedDataFrame.append(column: Column(name: "centroid_y", contents: starProperties.centroidY))

        // Add remaining columns from original (major_axis, minor_axis, rotation_angle)
        try addRemainingColumns(to: &reorderedDataFrame, from: dataFrame)

        // Add FWHM columns
        reorderedDataFrame.append(column: Column(name: "fwhm_major", contents: starProperties.fwhmMajor))
        reorderedDataFrame.append(column: Column(name: "fwhm_minor", contents: starProperties.fwhmMinor))

        // Replace binary-moment eccentricity with intensity-weighted moment eccentricity
        reorderedDataFrame.append(column: Column(name: "eccentricity", contents: starProperties.eccentricity))

        // Add saturated column
        reorderedDataFrame.append(column: Column(name: "saturated", contents: starProperties.saturated))

        outputTable.dataFrame = reorderedDataFrame
        outputs["pixel_coordinates"] = outputTable
    }

    /// Adds remaining columns (major_axis, minor_axis, rotation_angle) to the DataFrame.
    /// Eccentricity is intentionally excluded — it is computed from intensity-weighted moments
    /// and written separately in updateOutputTable.
    private func addRemainingColumns(to dataFrame: inout DataFrame, from sourceDataFrame: DataFrame) throws {
        if let majorAxisColumn = sourceDataFrame.columns.first(where: { $0.name == "major_axis" }) {
            let majorAxisValues: [Double] = (0..<sourceDataFrame.rows.count).compactMap { majorAxisColumn[$0] as? Double }
            dataFrame.append(column: Column(name: "major_axis", contents: majorAxisValues))
        }
        if let minorAxisColumn = sourceDataFrame.columns.first(where: { $0.name == "minor_axis" }) {
            let minorAxisValues: [Double] = (0..<sourceDataFrame.rows.count).compactMap { minorAxisColumn[$0] as? Double }
            dataFrame.append(column: Column(name: "minor_axis", contents: minorAxisValues))
        }
        if let rotationAngleColumn = sourceDataFrame.columns.first(where: { $0.name == "rotation_angle" }) {
            let rotationAngleValues: [Double] = (0..<sourceDataFrame.rows.count).compactMap { rotationAngleColumn[$0] as? Double }
            dataFrame.append(column: Column(name: "rotation_angle", contents: rotationAngleValues))
        }
    }

    /// Updates the median FWHM output table
    private func updateMedianFWHMTable(
        outputs: inout [String: ProcessData],
        statistics: FWHMStatistics
    ) throws {
        guard var medianTable = outputs["median_fwhm"] as? TableData else {
            return
        }

        var medianDataFrame = DataFrame()
        medianDataFrame.append(column: Column(name: "median_fwhm_major", contents: [statistics.medianMajor]))
        medianDataFrame.append(column: Column(name: "median_fwhm_minor", contents: [statistics.medianMinor]))
        medianDataFrame.append(
            column: Column(name: "sigma_clipped_mean_fwhm_major", contents: [statistics.sigmaClippedMeanMajor])
        )
        medianDataFrame.append(
            column: Column(name: "sigma_clipped_mean_fwhm_minor", contents: [statistics.sigmaClippedMeanMinor])
        )
        medianTable.dataFrame = medianDataFrame
        outputs["median_fwhm"] = medianTable
    }

    /// Structure to hold moment results from GPU
    private struct GPUMomentResults {
        let m00: Double
        let m10: Double
        let m01: Double
        let mu20: Double
        let mu11: Double
        let mu02: Double
        let maxPixelValue: Double  // Maximum pixel value for saturation detection
    }

    /// Calculates weighted image moments for all stars using GPU shader
    /// - Parameters:
    ///   - texture: The original (non-binary) image texture
    ///   - starInfo: Array of star centroids and region sizes
    ///   - device: Metal device
    ///   - commandQueue: Metal command queue
    /// - Returns: Array of moment results for each star
    /// - Throws: ProcessorExecutionError if calculation fails
    private func calculateMomentsGPU(
        texture: MTLTexture,
        starInfo: [(centroidX: Double, centroidY: Double, regionSize: Int)],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [GPUMomentResults] {
        guard !starInfo.isEmpty else {
            return []
        }

        // Load shader library
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)

        guard let momentFunction = library.makeFunction(name: "calculate_star_moments") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load FWHM shader function"
            )
        }

        let computePipelineState = try ProcessorHelpers.createComputePipelineState(
            function: momentFunction,
            device: device
        )

        // Prepare star info buffer
        struct StarInfo {
            var centroidX: Float
            var centroidY: Float
            var regionSize: Int32
        }

        let starInfoBufferData: [StarInfo] = starInfo.map {
            StarInfo(
                centroidX: Float($0.centroidX),
                centroidY: Float($0.centroidY),
                regionSize: Int32($0.regionSize)
            )
        }

        guard let starInfoBuffer = device.makeBuffer(
            bytes: starInfoBufferData,
            length: starInfoBufferData.count * MemoryLayout<StarInfo>.stride,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create star info buffer")
        }

        // Prepare moment results buffer
        struct MomentResults {
            var m00: Float
            var m10: Float
            var m01: Float
            var mu20: Float
            var mu11: Float
            var mu02: Float
            var maxPixelValue: Float
        }

        guard let momentResultsBuffer = device.makeBuffer(
            length: starInfo.count * MemoryLayout<MomentResults>.stride,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create moment results buffer")
        }

        // Initialize results buffer to zero
        let momentResultsPointer = momentResultsBuffer.contents().bindMemory(
            to: MomentResults.self,
            capacity: starInfo.count
        )
        for index in 0..<starInfo.count {
            momentResultsPointer[index] = MomentResults(
                m00: 0, m10: 0, m01: 0, mu20: 0, mu11: 0, mu02: 0, maxPixelValue: 0
            )
        }

        // Create command buffer and encoder
        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(computePipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(starInfoBuffer, offset: 0, index: 0)
        encoder.setBuffer(momentResultsBuffer, offset: 0, index: 1)

        // Dispatch one thread per star (1D dispatch)
        let threadgroupSize = MTLSize(width: 1, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(width: starInfo.count, height: 1, depth: 1)

        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        // Read results
        var results: [GPUMomentResults] = []
        results.reserveCapacity(starInfo.count)

        for index in 0..<starInfo.count {
            let moment = momentResultsPointer[index]
            results.append(GPUMomentResults(
                m00: Double(moment.m00),
                m10: Double(moment.m10),
                m01: Double(moment.m01),
                mu20: Double(moment.mu20),
                mu11: Double(moment.mu11),
                mu02: Double(moment.mu02),
                maxPixelValue: Double(moment.maxPixelValue)
            ))
        }

        return results
    }

    /// Calculates FWHM and eccentricity from intensity-weighted image moments.
    private func calculateFWHMFromMoments(moment: GPUMomentResults) -> FWHMMeasurements {
        guard moment.m00 > 0 else {
            return FWHMMeasurements(fwhmMajor: 0.0, fwhmMinor: 0.0, eccentricity: 0.0)
        }

        // Covariance matrix: [[μ20, μ11], [μ11, μ02]]
        // Calculate eigenvalues (major and minor axis variances)
        let trace = moment.mu20 + moment.mu02
        let determinant = moment.mu20 * moment.mu02 - moment.mu11 * moment.mu11
        let discriminant = trace * trace - 4 * determinant

        guard discriminant >= 0 else {
            return FWHMMeasurements(fwhmMajor: 0.0, fwhmMinor: 0.0, eccentricity: 0.0)
        }

        let sqrtDiscriminant = sqrt(discriminant)
        let lambda1 = (trace + sqrtDiscriminant) / 2.0
        let lambda2 = (trace - sqrtDiscriminant) / 2.0

        // Major axis variance is larger eigenvalue, minor axis variance is smaller
        let majorAxisVariance = max(lambda1, lambda2)
        let minorAxisVariance = min(lambda1, lambda2)

        // FWHM = 2.355 * sigma for a Gaussian profile; sigma² is the variance eigenvalue
        let sigmaMajor = sqrt(max(0.0, majorAxisVariance))
        let sigmaMinor = sqrt(max(0.0, minorAxisVariance))

        let fwhmMajor = 2.355 * sigmaMajor
        let fwhmMinor = 2.355 * sigmaMinor

        // Eccentricity from intensity-weighted axes: e = sqrt(1 - (σ_minor/σ_major)²)
        // Using the variance ratio avoids a redundant sqrt/square pair.
        let eccentricity: Double
        if sigmaMajor > 0 {
            eccentricity = sqrt(max(0.0, 1.0 - minorAxisVariance / majorAxisVariance))
        } else {
            eccentricity = 0.0
        }

        return FWHMMeasurements(fwhmMajor: fwhmMajor, fwhmMinor: fwhmMinor, eccentricity: eccentricity)
    }

    /// Calculates the median of an array
    /// - Parameter values: Array of values
    /// - Returns: Median value
    private func calculateMedian(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            return sorted[count / 2]
        }
    }

    /// Calculates σ-clipped mean of an array
    /// Removes outliers that are more than N standard deviations from the mean
    /// - Parameters:
    ///   - values: Array of values
    ///   - sigma: Number of standard deviations for clipping (default: 3.0)
    ///   - maxIterations: Maximum number of iterations (default: 5)
    /// - Returns: σ-clipped mean value
    private func calculateSigmaClippedMean(
        _ values: [Double],
        sigma: Double = 3.0,
        maxIterations: Int = 5
    ) -> Double {
        guard !values.isEmpty else { return 0.0 }
        guard values.count > 1 else { return values[0] }

        var clippedValues = values
        var previousMean = 0.0
        var previousStdDev = 0.0

        for iteration in 0..<maxIterations {
            // Calculate mean
            let mean = clippedValues.reduce(0.0, +) / Double(clippedValues.count)

            // Calculate standard deviation
            let variance = clippedValues.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(clippedValues.count)
            let stdDev = sqrt(max(0.0, variance))

            // Check for convergence (if mean and stddev haven't changed much, we're done)
            if iteration > 0 {
                let meanChange = abs(mean - previousMean)
                let stdDevChange = abs(stdDev - previousStdDev)
                if meanChange < 1e-6 && stdDevChange < 1e-6 {
                    break
                }
            }

            previousMean = mean
            previousStdDev = stdDev

            // Clip values outside mean ± sigma * stddev
            let lowerBound = mean - sigma * stdDev
            let upperBound = mean + sigma * stdDev
            clippedValues = clippedValues.filter { $0 >= lowerBound && $0 <= upperBound }

            // If we've removed too many values, stop
            if clippedValues.count < max(1, values.count / 4) {
                break
            }
        }

        // Return the final mean
        guard !clippedValues.isEmpty else { return previousMean }
        return clippedValues.reduce(0.0, +) / Double(clippedValues.count)
    }
}




