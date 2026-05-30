import Foundation
import Metal
import os
import TabularData

/// Estimates and subtracts the sky background using a mesh-based approach.
///
/// The image is divided into a grid of `cell_size × cell_size` pixel cells.  Each cell
/// computes a sigma-clipped median of its pixel values on the GPU (one threadgroup per
/// cell, 64 threads sharing a 256-bin histogram).  A single sigma-clipping pass rejects
/// bright outliers (stars, hot pixels, galaxy cores brighter than the cell sky floor)
/// before computing the median.  The resulting sparse grid of background values is then
/// bilinearly interpolated to full resolution and subtracted from the input frame.
///
/// This approach handles extended sources — galaxies, nebulae — far better than a
/// per-pixel local-median window, because the cell size can be made large enough that
/// each cell still samples enough sky even when an extended object fills part of the cell.
/// Stars remain detectable as residuals above the smooth, interpolated background surface.
///
/// **Inputs**
/// - `input_frame` (Frame) — grayscale frame to process.
///
/// **Outputs**
/// - `background_frame`           (Frame)     — smooth background surface.
/// - `background_subtracted_frame`(Frame)     — input minus background, clamped to [0, 1].
/// - `background_level`           (TableData) — one-row table with background statistics.
///
/// **background_level columns**
/// | Column                    | Description                                           |
/// |---------------------------|-------------------------------------------------------|
/// | `background_level`        | Mean background level, normalised 0–1.                |
/// | `background_noise_sigma`  | Per-pixel sky noise σ (NMAD of signed residuals, 0–1).|
/// | `background_level_adu`    | Background in ADU (when FITS scale info available).   |
/// | `background_noise_sigma_adu` | Noise σ in ADU (when FITS scale info available).   |
///
/// **Parameters**
/// - `cell_size` (default `64`) — mesh cell size in pixels.  Increase for frames dominated
///   by a large galaxy or nebula (e.g. `128`–`256`).  The alias `window_size` is accepted
///   for backward compatibility.
public struct BackgroundEstimationProcessor: Processor {

    public var id: String { "background_estimation" }
    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (inputFrame, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        Logger.processor.debug(
            "Estimating background — mesh approach (image: \(inputTexture.width)×\(inputTexture.height))"
        )

        // cell_size: how large each grid square is.  Larger = smoother background, better
        // for extended objects.  window_size is accepted as a backward-compatible alias.
        let cellSize: Int = {
            let raw = (parameters["cell_size"] ?? parameters["window_size"])?.doubleValue
            return max(8, Int(raw ?? 64))
        }()

        let library = try ProcessorHelpers.loadShaderLibrary(device: device)

        // Allocate output textures
        let bgDesc = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let backgroundTexture = try ProcessorHelpers.createTexture(descriptor: bgDesc, device: device)

        let subDesc = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height
        )
        let subtractedTexture = try ProcessorHelpers.createTexture(descriptor: subDesc, device: device)

        // Step 1 + 2: compute per-cell sigma-clipped medians → bilinear interpolation
        try performMeshBackgroundEstimation(
            inputTexture: inputTexture,
            backgroundTexture: backgroundTexture,
            cellSize: cellSize,
            library: library,
            device: device,
            commandQueue: commandQueue
        )

        // Step 3: subtract (clamps to 0 — used by downstream threshold / detection steps)
        guard let subtractFn = library.makeFunction(name: "local_median_subtract") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load local_median_subtract shader"
            )
        }
        let subtractPSO = try ProcessorHelpers.createComputePipelineState(
            function: subtractFn, device: device
        )
        var minVal: Float = 0.0
        var maxVal: Float = 1.0
        let minBuf = try ProcessorHelpers.createBuffer(from: &minVal, device: device)
        let maxBuf = try ProcessorHelpers.createBuffer(from: &maxVal, device: device)
        try subtractBackgroundFromInput(
            inputTexture: inputTexture,
            backgroundTexture: backgroundTexture,
            subtractedTexture: subtractedTexture,
            subtractPipelineState: subtractPSO,
            minValueBuffer: minBuf,
            maxValueBuffer: maxBuf,
            commandQueue: commandQueue
        )

        // Step 4: compute statistics and write output table / frames
        try finalizeOutputs(
            inputFrame: inputFrame,
            inputTexture: inputTexture,
            backgroundTexture: backgroundTexture,
            subtractedTexture: subtractedTexture,
            outputs: &outputs,
            device: device,
            commandQueue: commandQueue
        )
    }

    // MARK: - Mesh background estimation

    private func performMeshBackgroundEstimation(
        inputTexture: MTLTexture,
        backgroundTexture: MTLTexture,
        cellSize: Int,
        library: MTLLibrary,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let numCellsX   = (inputTexture.width  + cellSize - 1) / cellSize
        let numCellsY   = (inputTexture.height + cellSize - 1) / cellSize
        let numCells    = numCellsX * numCellsY
        let numHistBins = 256

        Logger.processor.debug("Mesh grid: \(numCellsX)×\(numCellsY) cells (\(cellSize)px each)")

        guard let medianFn = library.makeFunction(name: "compute_mesh_cell_median"),
              let interpFn = library.makeFunction(name: "interpolate_mesh_background") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load mesh background shader functions"
            )
        }
        let medianPSO = try ProcessorHelpers.createComputePipelineState(function: medianFn, device: device)
        let interpPSO = try ProcessorHelpers.createComputePipelineState(function: interpFn, device: device)

        // Buffer that receives one Float32 per cell from the GPU
        let cellBufLen = numCells * MemoryLayout<Float32>.size
        guard let cellBuf = device.makeBuffer(length: cellBufLen, options: [.storageModeShared]) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create cell medians buffer")
        }

        var cellSizeInt    = Int32(cellSize)
        var numCellsXInt   = Int32(numCellsX)
        var numHistBinsInt = Int32(numHistBins)
        let cellSizeBuf    = try ProcessorHelpers.createBuffer(from: &cellSizeInt,    device: device)
        let numCellsXBuf   = try ProcessorHelpers.createBuffer(from: &numCellsXInt,   device: device)
        let numHistBinsBuf = try ProcessorHelpers.createBuffer(from: &numHistBinsInt, device: device)

        // Dispatch: one threadgroup per cell, 64 threads share a 256-bin histogram
        let threadsPerGroup = 64
        let tgMemSize       = numHistBins * MemoryLayout<Int32>.size

        let cb1  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc1 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb1)
        enc1.setComputePipelineState(medianPSO)
        enc1.setTexture(inputTexture,  index: 0)
        enc1.setBuffer(cellBuf,        offset: 0, index: 0)
        enc1.setBuffer(cellSizeBuf,    offset: 0, index: 1)
        enc1.setBuffer(numCellsXBuf,   offset: 0, index: 2)
        enc1.setBuffer(numHistBinsBuf, offset: 0, index: 3)
        enc1.setThreadgroupMemoryLength(tgMemSize, index: 0)
        enc1.dispatchThreadgroups(
            MTLSize(width: numCellsX, height: numCellsY, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        )
        enc1.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb1)

        // Upload the small cell-median grid as an R32Float texture for bilinear sampling
        let cellTexDesc             = MTLTextureDescriptor()
        cellTexDesc.textureType     = .type2D
        cellTexDesc.pixelFormat     = .r32Float
        cellTexDesc.width           = numCellsX
        cellTexDesc.height          = numCellsY
        cellTexDesc.usage           = [.shaderRead]
        cellTexDesc.storageMode     = .shared
        guard let cellTex = device.makeTexture(descriptor: cellTexDesc) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create cell grid texture")
        }
        cellTex.replace(
            region: MTLRegionMake2D(0, 0, numCellsX, numCellsY),
            mipmapLevel: 0,
            withBytes: cellBuf.contents(),
            bytesPerRow: numCellsX * MemoryLayout<Float32>.size
        )

        // Bilinear interpolation → full-resolution background texture
        var invCellSize = Float(1.0) / Float(cellSize)
        let invCellBuf  = try ProcessorHelpers.createBuffer(from: &invCellSize, device: device)

        let (tgSize, tgPerGrid) = ProcessorHelpers.calculateThreadgroups(for: backgroundTexture)
        let cb2  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc2 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb2)
        enc2.setComputePipelineState(interpPSO)
        enc2.setTexture(cellTex,           index: 0)
        enc2.setTexture(backgroundTexture, index: 1)
        enc2.setBuffer(invCellBuf, offset: 0, index: 0)
        enc2.dispatchThreadgroups(tgPerGrid, threadsPerThreadgroup: tgSize)
        enc2.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb2)
    }

    // MARK: - Background subtraction

    private func subtractBackgroundFromInput(
        inputTexture: MTLTexture,
        backgroundTexture: MTLTexture,
        subtractedTexture: MTLTexture,
        subtractPipelineState: MTLComputePipelineState,
        minValueBuffer: MTLBuffer,
        maxValueBuffer: MTLBuffer,
        commandQueue: MTLCommandQueue
    ) throws {
        let (tgSize, tgPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)
        let cb   = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc  = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb)
        enc.setComputePipelineState(subtractPipelineState)
        enc.setTexture(inputTexture,      index: 0)
        enc.setTexture(backgroundTexture, index: 1)
        enc.setTexture(subtractedTexture, index: 2)
        enc.setBuffer(minValueBuffer, offset: 0, index: 0)
        enc.setBuffer(maxValueBuffer, offset: 0, index: 1)
        enc.dispatchThreadgroups(tgPerGrid, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb)
    }

    // MARK: - Finalise outputs

    private func finalizeOutputs(
        inputFrame: Frame,
        inputTexture: MTLTexture,
        backgroundTexture: MTLTexture,
        subtractedTexture: MTLTexture,
        outputs: inout [String: ProcessData],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let backgroundLevel = try calculateAverageBackgroundLevel(
            texture: backgroundTexture,
            device: device,
            commandQueue: commandQueue
        )

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

        // GPU-based NMAD of signed (input − background) residuals — see calculateNoiseSigma
        let noiseSigma = (try? calculateNoiseSigma(
            inputTexture: inputTexture,
            backgroundTexture: backgroundTexture,
            device: device,
            commandQueue: commandQueue
        )) ?? 0.0

        if var backgroundLevelTable = outputs["background_level"] as? TableData {
            var df = DataFrame()
            df.append(column: Column(name: "background_level",       contents: [backgroundLevel]))
            df.append(column: Column(name: "background_noise_sigma", contents: [noiseSigma]))
            if let fitsMin = inputFrame.fitsMinValue, let fitsMax = inputFrame.fitsMaxValue {
                let scale = fitsMax - fitsMin
                df.append(column: Column(name: "background_level_adu",       contents: [backgroundLevel * scale + fitsMin]))
                df.append(column: Column(name: "background_noise_sigma_adu", contents: [noiseSigma * scale]))
            }
            backgroundLevelTable.dataFrame = df
            outputs["background_level"] = backgroundLevelTable
        }

        let aduInfo: String = inputFrame.toADU(backgroundLevel)
            .map { String(format: " (%.1f ADU)", $0) } ?? ""
        let sigmaInfo: String = {
            guard let fitsMin = inputFrame.fitsMinValue,
                  let fitsMax = inputFrame.fitsMaxValue else { return "" }
            return String(format: ", σ=%.2f ADU", noiseSigma * (fitsMax - fitsMin))
        }()
        Logger.processor.info(
            "Background estimation complete (level: \(backgroundLevel)\(aduInfo)\(sigmaInfo))"
        )
    }

    // MARK: - Background level sampling

    private func calculateAverageBackgroundLevel(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Double {
        let sampleRate   = 10
        let sampleWidth  = max(1, texture.width  / sampleRate)
        let sampleHeight = max(1, texture.height / sampleRate)
        let bytesPerRow  = sampleWidth * MemoryLayout<Float32>.size
        let bufferSize   = bytesPerRow * sampleHeight

        guard let readBuf = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create background-level read buffer")
        }
        guard let cb  = commandQueue.makeCommandBuffer(),
              let enc = cb.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create blit encoder")
        }
        enc.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sampleWidth, height: sampleHeight, depth: 1),
            to: readBuf,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        enc.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb)

        let ptr    = readBuf.contents().bindMemory(to: Float32.self, capacity: sampleWidth * sampleHeight)
        let pixels = Array(UnsafeBufferPointer(start: ptr, count: sampleWidth * sampleHeight))
        return Double(pixels.reduce(0.0, +) / Float(pixels.count))
    }

    // MARK: - GPU NMAD noise sigma

    /// Two-pass GPU histogram NMAD of signed (input − background) residuals.
    ///
    /// The `local_median_subtract` shader clamps its output to [0, 1], so the
    /// already-subtracted texture cannot be used here — its sky pixels are all 0.
    /// Instead, both textures are read raw inside the shader and the signed difference
    /// is computed per thread, preserving the full noise distribution.
    ///
    /// Pass 1: `build_residual_histogram` → CPU finds median from 512-bin histogram.
    /// Pass 2: `build_residual_mad_histogram` → CPU finds MAD from 512-bin histogram.
    /// σ_NMAD = 1.4826 × MAD.  Total CPU←GPU transfer: ~2 KB.
    private func calculateNoiseSigma(
        inputTexture: MTLTexture,
        backgroundTexture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> Double {
        let numBins       = 512
        let residualRange: Float = 0.1   // ±10 % of normalised range

        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let histFn = library.makeFunction(name: "build_residual_histogram"),
              let madFn  = library.makeFunction(name: "build_residual_mad_histogram") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load residual histogram shader functions"
            )
        }
        let histPSO = try ProcessorHelpers.createComputePipelineState(function: histFn, device: device)
        let madPSO  = try ProcessorHelpers.createComputePipelineState(function: madFn,  device: device)

        let histByteCount = numBins * MemoryLayout<Int32>.size
        guard let histBuf = device.makeBuffer(length: histByteCount, options: [.storageModeShared]),
              let madBuf  = device.makeBuffer(length: histByteCount, options: [.storageModeShared]) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create NMAD histogram buffers")
        }
        memset(histBuf.contents(), 0, histByteCount)
        memset(madBuf.contents(),  0, histByteCount)

        var numBinsInt  = Int32(numBins)
        var minResidual = -residualRange
        var maxResidual =  residualRange
        let numBinsBuf  = try ProcessorHelpers.createBuffer(from: &numBinsInt,  device: device)
        let minResBuf   = try ProcessorHelpers.createBuffer(from: &minResidual, device: device)
        let maxResBuf   = try ProcessorHelpers.createBuffer(from: &maxResidual, device: device)

        let (tgSize, tgPerGrid) = ProcessorHelpers.calculateThreadgroups(for: inputTexture)

        let cb1  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc1 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb1)
        enc1.setComputePipelineState(histPSO)
        enc1.setTexture(inputTexture,      index: 0)
        enc1.setTexture(backgroundTexture, index: 1)
        enc1.setBuffer(histBuf,    offset: 0, index: 0)
        enc1.setBuffer(numBinsBuf, offset: 0, index: 1)
        enc1.setBuffer(minResBuf,  offset: 0, index: 2)
        enc1.setBuffer(maxResBuf,  offset: 0, index: 3)
        enc1.dispatchThreadgroups(tgPerGrid, threadsPerThreadgroup: tgSize)
        enc1.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb1)

        let histPtr     = histBuf.contents().bindMemory(to: Int32.self, capacity: numBins)
        let histArray   = Array(UnsafeBufferPointer(start: histPtr, count: numBins))
        let totalPixels = histArray.reduce(0) { $0 + Int($1) }
        let medianRes   = medianFromHistogram(
            histArray, numBins: numBins, total: totalPixels,
            minVal: Double(minResidual), maxVal: Double(maxResidual)
        )

        var medianFloat = Float(medianRes)
        var maxAbsDev   = residualRange
        let medBuf    = try ProcessorHelpers.createBuffer(from: &medianFloat, device: device)
        let maxAbsBuf = try ProcessorHelpers.createBuffer(from: &maxAbsDev,   device: device)

        let cb2  = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc2 = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb2)
        enc2.setComputePipelineState(madPSO)
        enc2.setTexture(inputTexture,      index: 0)
        enc2.setTexture(backgroundTexture, index: 1)
        enc2.setBuffer(madBuf,     offset: 0, index: 0)
        enc2.setBuffer(numBinsBuf, offset: 0, index: 1)
        enc2.setBuffer(maxAbsBuf,  offset: 0, index: 2)
        enc2.setBuffer(medBuf,     offset: 0, index: 3)
        enc2.dispatchThreadgroups(tgPerGrid, threadsPerThreadgroup: tgSize)
        enc2.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb2)

        let madPtr   = madBuf.contents().bindMemory(to: Int32.self, capacity: numBins)
        let madArray = Array(UnsafeBufferPointer(start: madPtr, count: numBins))
        let mad      = medianFromHistogram(
            madArray, numBins: numBins, total: totalPixels,
            minVal: 0.0, maxVal: Double(maxAbsDev)
        )
        return 1.4826 * mad
    }

    private func medianFromHistogram(
        _ histogram: [Int32], numBins: Int, total: Int,
        minVal: Double, maxVal: Double
    ) -> Double {
        guard total > 0 else { return 0 }
        let half     = (total + 1) / 2
        let binWidth = (maxVal - minVal) / Double(numBins)
        var cumulative = 0
        for (i, count) in histogram.enumerated() {
            cumulative += Int(count)
            if cumulative >= half {
                return minVal + (Double(i) + 0.5) * binWidth
            }
        }
        return maxVal
    }
}
