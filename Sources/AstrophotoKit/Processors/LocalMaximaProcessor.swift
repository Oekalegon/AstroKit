import Foundation
import Metal
import TabularData
import os

/// GPU-accelerated local maxima detector.
///
/// Finds pixels that are strict 8-neighbour maxima in the continuous
/// background-subtracted frame *within* the binary mask produced by
/// erosion + dilation. Each such pixel is a candidate star peak.
///
/// After GPU detection a CPU non-maximum suppression pass (greedy, sorted
/// by descending intensity) discards peaks closer than `min_distance`
/// pixels to an already-accepted peak.
///
/// The output table has the same column schema as ConnectedComponentsProcessor
/// so all downstream steps (FWHM, quads, overlay …) work unchanged.
public struct LocalMaximaProcessor: Processor {

    public var id: String { "local_maxima" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let bgFrame = inputs["input_frame"] as? Frame,
              let bgTexture = bgFrame.texture else {
            throw ProcessorExecutionError.missingRequiredInput("input_frame")
        }
        guard let maskFrame = inputs["mask_frame"] as? Frame,
              let maskTexture = maskFrame.texture else {
            throw ProcessorExecutionError.missingRequiredInput("mask_frame")
        }

        let minDistance = parameters["min_distance"]?.doubleValue ?? 5.0

        Logger.processor.debug(
            "Local maxima detection (\(bgTexture.width)×\(bgTexture.height), minDist: \(minDistance))"
        )

        let rawPeaks = try detectPeaksOnGPU(
            bgTexture: bgTexture,
            maskTexture: maskTexture,
            device: device,
            commandQueue: commandQueue
        )

        Logger.processor.debug("GPU found \(rawPeaks.count) raw local maxima")

        let peaks = nonMaximumSuppression(peaks: rawPeaks, minDistance: minDistance)

        Logger.processor.info("Local maxima: \(peaks.count) peaks after NMS (min_distance: \(minDistance))")

        if var outputTable = outputs["pixel_coordinates"] as? TableData {
            outputTable.dataFrame = buildDataFrame(from: peaks)
            outputs["pixel_coordinates"] = outputTable
        }
    }

    // MARK: - GPU Detection

    private struct Peak {
        let x: Int
        let y: Int
        let intensity: Float
    }

    private struct GPUPeak {
        var x: Int32
        var y: Int32
        var intensity: Float
    }

    private func detectPeaksOnGPU(
        bgTexture: MTLTexture,
        maskTexture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [Peak] {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)

        guard let countFn = library.makeFunction(name: "count_local_maxima"),
              let collectFn = library.makeFunction(name: "collect_local_maxima") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load local_maxima shader functions"
            )
        }

        let countPSO = try ProcessorHelpers.createComputePipelineState(function: countFn, device: device)
        let collectPSO = try ProcessorHelpers.createComputePipelineState(function: collectFn, device: device)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: bgTexture)

        // Pass 1 – count
        guard let countBuf = device.makeBuffer(length: MemoryLayout<Int32>.size, options: .storageModeShared) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create count buffer")
        }
        countBuf.contents().bindMemory(to: Int32.self, capacity: 1)[0] = 0

        let cb1 = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc1 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb1)
        enc1.setComputePipelineState(countPSO)
        enc1.setTexture(bgTexture, index: 0)
        enc1.setTexture(maskTexture, index: 1)
        enc1.setBuffer(countBuf, offset: 0, index: 0)
        enc1.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        enc1.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb1)

        let peakCount = Int(countBuf.contents().load(as: Int32.self))
        guard peakCount > 0 else { return [] }

        // Pass 2 – collect
        let peakBufSize = peakCount * MemoryLayout<GPUPeak>.stride
        guard let peakBuf = device.makeBuffer(length: peakBufSize, options: .storageModeShared) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create peak buffer")
        }
        guard let indexBuf = device.makeBuffer(length: MemoryLayout<Int32>.size, options: .storageModeShared) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create index buffer")
        }
        indexBuf.contents().bindMemory(to: Int32.self, capacity: 1)[0] = 0

        let cb2 = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc2 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb2)
        enc2.setComputePipelineState(collectPSO)
        enc2.setTexture(bgTexture, index: 0)
        enc2.setTexture(maskTexture, index: 1)
        enc2.setBuffer(peakBuf, offset: 0, index: 0)
        enc2.setBuffer(indexBuf, offset: 0, index: 1)
        enc2.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        enc2.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb2)

        let ptr = peakBuf.contents().bindMemory(to: GPUPeak.self, capacity: peakCount)
        return (0..<peakCount).map { i in
            Peak(x: Int(ptr[i].x), y: Int(ptr[i].y), intensity: ptr[i].intensity)
        }
    }

    // MARK: - CPU Non-Maximum Suppression

    private func nonMaximumSuppression(peaks: [Peak], minDistance: Double) -> [Peak] {
        let sorted = peaks.sorted { $0.intensity > $1.intensity }
        let minDist2 = minDistance * minDistance
        var accepted: [Peak] = []
        accepted.reserveCapacity(min(sorted.count, 10_000))

        for candidate in sorted {
            let cx = Double(candidate.x)
            let cy = Double(candidate.y)
            let suppressed = accepted.contains { a in
                let dx = Double(a.x) - cx
                let dy = Double(a.y) - cy
                return dx * dx + dy * dy < minDist2
            }
            if !suppressed { accepted.append(candidate) }
        }

        return accepted
    }

    // MARK: - Output DataFrame

    /// Initial major/minor axis estimate fed to FWHMProcessor for region sizing.
    /// FWHMProcessor uses max(major, minor) × 4, clamped to [15, 200].
    /// 7.5 → region = 30 px, suitable for typical stars (FWHM < 8 px).
    private let defaultAxisRadius: Double = 7.5

    private func buildDataFrame(from peaks: [Peak]) -> DataFrame {
        var df = DataFrame()
        let n = peaks.count
        df.append(column: Column(name: "id", contents: Array(0..<n)))
        df.append(column: Column(name: "area", contents: Array(repeating: 0, count: n)))
        df.append(column: Column(name: "centroid_x", contents: peaks.map { Double($0.x) }))
        df.append(column: Column(name: "centroid_y", contents: peaks.map { Double($0.y) }))
        df.append(column: Column(name: "major_axis", contents: Array(repeating: defaultAxisRadius, count: n)))
        df.append(column: Column(name: "minor_axis", contents: Array(repeating: defaultAxisRadius, count: n)))
        df.append(column: Column(name: "eccentricity", contents: Array(repeating: 0.0, count: n)))
        df.append(column: Column(name: "rotation_angle", contents: Array(repeating: 0.0, count: n)))
        return df
    }
}
