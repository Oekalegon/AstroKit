import Foundation
import Metal
import TabularData
import os

/// Processor for calculating Half-Flux Diameter (HFD) for detected stars or out-of-focus donuts.
///
/// HFD = 2 * Σ(d_i * I_i) / Σ(I_i), where d_i is the distance of pixel i from the flux centroid.
/// This metric works for both sharply-focused stars (small HFD) and out-of-focus reflector donut
/// stars (larger HFD proportional to defocus), making it suitable for autofocus routines.
///
/// Mode is determined automatically by which input is present:
/// - `pixel_coordinates` present → focused-star mode (uses ConnectedComponents / FWHM star table)
/// - `donuts` present → donut mode (uses HoughCircleProcessor donut table)
public struct HFDProcessor: Processor {

    public var id: String { "hfd" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        let regionMultiplier = parameters["region_multiplier"]?.doubleValue ?? 4.0
        let minRegionSize    = parameters["min_region_size"]?.intValue ?? 15
        let maxRegionSize    = parameters["max_region_size"]?.intValue ?? 400
        let donutMargin      = parameters["donut_margin"]?.intValue ?? 20

        // Determine mode and build HFDInfo array
        let (hfdInfoArray, mode) = try buildHFDInfoArray(
            inputs: inputs,
            regionMultiplier: regionMultiplier,
            minRegionSize: minRegionSize,
            maxRegionSize: maxRegionSize,
            donutMargin: donutMargin
        )

        Logger.processor.debug("Calculating HFD for \(hfdInfoArray.count) \(mode) targets")

        guard !hfdInfoArray.isEmpty else {
            try writeEmptyOutputs(outputs: &outputs, mode: mode)
            return
        }

        // Run GPU kernel
        let gpuResults = try calculateHFDGPU(
            texture: inputTexture,
            hfdInfoArray: hfdInfoArray,
            device: device,
            commandQueue: commandQueue
        )

        // Compute statistics
        let saturationThreshold = 0.9
        let hfdValues  = gpuResults.map { Double($0.hfd) }
        let fluxValues = gpuResults.map { Double($0.sumIntensity) }
        let saturated  = gpuResults.map { Double($0.maxPixelValue) >= saturationThreshold }

        let validHFDs = zip(hfdValues, saturated).compactMap { v, s in (!s && v > 0) ? v : nil }
        let medianHFD = validHFDs.isEmpty ? 0.0 : calculateMedian(validHFDs)
        let sigmaClippedMean = validHFDs.isEmpty ? 0.0 : calculateSigmaClippedMean(validHFDs)

        let hfdLogMsg = String(
            format: "HFD calculation complete. Median HFD: %.3f, stars: %d/%d, mode: %@",
            medianHFD, validHFDs.count, hfdValues.count, mode
        )
        Logger.processor.info("\(hfdLogMsg)")

        try writeHFDMeasurements(
            outputs: &outputs,
            gpuResults: gpuResults,
            hfdValues: hfdValues,
            fluxValues: fluxValues,
            saturated: saturated
        )

        try writeMedianHFD(
            outputs: &outputs,
            medianHFD: medianHFD,
            sigmaClippedMean: sigmaClippedMean,
            starCount: validHFDs.count,
            mode: mode
        )
    }

    // MARK: - Input Handling

    /// Builds the array of HFDInfo structs from either a focused-star or donut input table.
    private func buildHFDInfoArray(
        inputs: [String: ProcessData],
        regionMultiplier: Double,
        minRegionSize: Int,
        maxRegionSize: Int,
        donutMargin: Int
    ) throws -> ([(centroidX: Double, centroidY: Double, regionSize: Int, isDonut: Bool, innerR: Double)], String) {

        // Donut mode: donuts table from HoughCircleProcessor
        if let donutTable = inputs["donuts"] as? TableData,
           let df = donutTable.dataFrame,
           df.rows.count > 0 {
            let infoArray = try buildDonutModeInfo(from: df, donutMargin: donutMargin, maxRegionSize: maxRegionSize)
            return (infoArray, "donut")
        }

        // Focused-star mode: pixel_coordinates table from FWHMProcessor
        if let starTable = inputs["pixel_coordinates"] as? TableData,
           let df = starTable.dataFrame,
           df.rows.count > 0 {
            let infoArray = try buildFocusedModeInfo(
                from: df,
                regionMultiplier: regionMultiplier,
                minRegionSize: minRegionSize,
                maxRegionSize: maxRegionSize
            )
            return (infoArray, "focused")
        }

        throw ProcessorExecutionError.missingRequiredInput(
            "Either 'pixel_coordinates' or 'donuts' must be provided"
        )
    }

    private func buildFocusedModeInfo(
        from df: DataFrame,
        regionMultiplier: Double,
        minRegionSize: Int,
        maxRegionSize: Int
    ) throws -> [(centroidX: Double, centroidY: Double, regionSize: Int, isDonut: Bool, innerR: Double)] {
        guard let cxCol = df.columns.first(where: { $0.name == "centroid_x" }),
              let cyCol = df.columns.first(where: { $0.name == "centroid_y" }),
              let majorCol = df.columns.first(where: { $0.name == "major_axis" }) else {
            throw ProcessorExecutionError.executionFailed(
                "pixel_coordinates table missing centroid_x, centroid_y, or major_axis columns"
            )
        }

        return (0..<df.rows.count).map { i in
            let cx = (cxCol[i] as? Double) ?? 0.0
            let cy = (cyCol[i] as? Double) ?? 0.0
            let major = (majorCol[i] as? Double) ?? 10.0
            var size = Int(ceil(major * regionMultiplier))
            size = max(minRegionSize, min(size, maxRegionSize))
            if size % 2 == 0 { size += 1 }
            return (centroidX: cx, centroidY: cy, regionSize: size, isDonut: false, innerR: 0.0)
        }
    }

    private func buildDonutModeInfo(
        from df: DataFrame,
        donutMargin: Int,
        maxRegionSize: Int
    ) throws -> [(centroidX: Double, centroidY: Double, regionSize: Int, isDonut: Bool, innerR: Double)] {
        guard let ocxCol = df.columns.first(where: { $0.name == "outer_cx" }),
              let ocyCol = df.columns.first(where: { $0.name == "outer_cy" }),
              let orCol  = df.columns.first(where: { $0.name == "outer_r" }),
              let irCol  = df.columns.first(where: { $0.name == "inner_r" }) else {
            throw ProcessorExecutionError.executionFailed(
                "donuts table missing outer_cx, outer_cy, outer_r, or inner_r columns"
            )
        }

        return (0..<df.rows.count).map { i in
            let cx = (ocxCol[i] as? Double) ?? 0.0
            let cy = (ocyCol[i] as? Double) ?? 0.0
            let outerR = (orCol[i] as? Double) ?? 50.0
            let innerR = (irCol[i] as? Double) ?? 20.0
            var size = Int((outerR + Double(donutMargin)) * 2)
            size = min(size, maxRegionSize)
            if size % 2 == 0 { size += 1 }
            return (centroidX: cx, centroidY: cy, regionSize: size, isDonut: true, innerR: innerR)
        }
    }

    // MARK: - GPU Dispatch

    /// Mirror of HFDInfo in HFDShader.metal
    private struct GPUHFDInfo {
        var centroidX: Float
        var centroidY: Float
        var regionSize: Int32
        var isDonut: Int32
        var innerR: Float
    }

    /// Mirror of HFDResults in HFDShader.metal
    private struct GPUHFDResults {
        var sumDistIntensity: Float
        var sumIntensity: Float
        var hfd: Float
        var centroidX: Float
        var centroidY: Float
        var maxPixelValue: Float
    }

    private func calculateHFDGPU(
        texture: MTLTexture,
        hfdInfoArray: [(centroidX: Double, centroidY: Double, regionSize: Int, isDonut: Bool, innerR: Double)],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [GPUHFDResults] {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)

        guard let hfdFunction = library.makeFunction(name: "calculate_hfd") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load calculate_hfd shader function")
        }

        let pipelineState = try ProcessorHelpers.createComputePipelineState(
            function: hfdFunction,
            device: device
        )

        let infoData: [GPUHFDInfo] = hfdInfoArray.map {
            GPUHFDInfo(
                centroidX: Float($0.centroidX),
                centroidY: Float($0.centroidY),
                regionSize: Int32($0.regionSize),
                isDonut: $0.isDonut ? 1 : 0,
                innerR: Float($0.innerR)
            )
        }

        guard let infoBuffer = device.makeBuffer(
            bytes: infoData,
            length: infoData.count * MemoryLayout<GPUHFDInfo>.stride,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create HFD info buffer")
        }

        guard let resultsBuffer = device.makeBuffer(
            length: hfdInfoArray.count * MemoryLayout<GPUHFDResults>.stride,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create HFD results buffer")
        }

        // Zero-initialise results
        let resultsPtr = resultsBuffer.contents().bindMemory(to: GPUHFDResults.self, capacity: hfdInfoArray.count)
        for i in 0..<hfdInfoArray.count {
            resultsPtr[i] = GPUHFDResults(
                sumDistIntensity: 0, sumIntensity: 0, hfd: 0,
                centroidX: 0, centroidY: 0, maxPixelValue: 0
            )
        }

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let encoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(infoBuffer,    offset: 0, index: 0)
        encoder.setBuffer(resultsBuffer, offset: 0, index: 1)

        // One thread per star / donut
        encoder.dispatchThreadgroups(
            MTLSize(width: hfdInfoArray.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(commandBuffer)

        return (0..<hfdInfoArray.count).map { resultsPtr[$0] }
    }

    // MARK: - Output Writing

    private func writeHFDMeasurements(
        outputs: inout [String: ProcessData],
        gpuResults: [GPUHFDResults],
        hfdValues: [Double],
        fluxValues: [Double],
        saturated: [Bool]
    ) throws {
        guard var table = outputs["hfd_measurements"] as? TableData else { return }

        var df = DataFrame()
        df.append(column: Column(name: "id",          contents: Array(0..<gpuResults.count)))
        df.append(column: Column(name: "centroid_x",  contents: gpuResults.map { Double($0.centroidX) }))
        df.append(column: Column(name: "centroid_y",  contents: gpuResults.map { Double($0.centroidY) }))
        df.append(column: Column(name: "hfd",         contents: hfdValues))
        df.append(column: Column(name: "flux",        contents: fluxValues))
        df.append(column: Column(name: "saturated",   contents: saturated))

        table.dataFrame = df
        outputs["hfd_measurements"] = table
    }

    private func writeMedianHFD(
        outputs: inout [String: ProcessData],
        medianHFD: Double,
        sigmaClippedMean: Double,
        starCount: Int,
        mode: String
    ) throws {
        guard var table = outputs["median_hfd"] as? TableData else { return }

        var df = DataFrame()
        df.append(column: Column(name: "median_hfd",              contents: [medianHFD]))
        df.append(column: Column(name: "sigma_clipped_mean_hfd",  contents: [sigmaClippedMean]))
        df.append(column: Column(name: "star_count",              contents: [starCount]))
        df.append(column: Column(name: "mode",                    contents: [mode]))

        table.dataFrame = df
        outputs["median_hfd"] = table
    }

    private func writeEmptyOutputs(
        outputs: inout [String: ProcessData],
        mode: String
    ) throws {
        if var table = outputs["hfd_measurements"] as? TableData {
            var df = DataFrame()
            df.append(column: Column(name: "id",         contents: [] as [Int]))
            df.append(column: Column(name: "centroid_x", contents: [] as [Double]))
            df.append(column: Column(name: "centroid_y", contents: [] as [Double]))
            df.append(column: Column(name: "hfd",        contents: [] as [Double]))
            df.append(column: Column(name: "flux",       contents: [] as [Double]))
            df.append(column: Column(name: "saturated",  contents: [] as [Bool]))
            table.dataFrame = df
            outputs["hfd_measurements"] = table
        }
        try writeMedianHFD(
            outputs: &outputs,
            medianHFD: 0.0,
            sigmaClippedMean: 0.0,
            starCount: 0,
            mode: mode
        )
    }

    // MARK: - Statistics

    private func calculateMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    private func calculateSigmaClippedMean(
        _ values: [Double],
        sigma: Double = 3.0,
        maxIterations: Int = 5
    ) -> Double {
        guard values.count > 1 else { return values.first ?? 0.0 }
        var clipped = values
        var prevMean = 0.0, prevStd = 0.0
        for iter in 0..<maxIterations {
            let mean = clipped.reduce(0, +) / Double(clipped.count)
            let variance = clipped.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(clipped.count)
            let std = sqrt(max(0, variance))
            if iter > 0 && abs(mean - prevMean) < 1e-6 && abs(std - prevStd) < 1e-6 { break }
            prevMean = mean; prevStd = std
            clipped = clipped.filter { $0 >= mean - sigma * std && $0 <= mean + sigma * std }
            if clipped.count < max(1, values.count / 4) { break }
        }
        return clipped.isEmpty ? prevMean : clipped.reduce(0, +) / Double(clipped.count)
    }
}

