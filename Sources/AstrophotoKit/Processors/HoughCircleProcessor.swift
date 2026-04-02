import Foundation
import Metal
import TabularData
import os

/// Processor that detects circular/donut-shaped out-of-focus star images in a reflector
/// telescope image using a gradient-directed Hough Circle Transform on the GPU.
///
/// Each out-of-focus star in a reflector appears as a donut: an outer circle (the
/// defocused star disc) with a concentric inner dark circle (the shadow of the secondary
/// mirror).  This processor finds both circles for each star and reports the offset
/// between their centres, which encodes the collimation error.
///
/// **Memory strategy**
/// The full-image Hough accumulator would be impractically large.  Instead the processor
/// works per-candidate: it first locates bright-blob candidate positions on the CPU by
/// scanning the image at a coarse stride, then for each candidate it:
///   1. Extracts a small crop centred on the candidate.
///   2. Runs Sobel gradient detection on the crop (GPU).
///   3. Runs gradient-directed Hough voting on the crop (GPU).
///   4. Scans the 3-D accumulator (CPU) for circle peaks.
///   5. Attempts to pair outer+inner circles into donut descriptions.
/// The accumulator buffer is released after each candidate.
///
/// **Inputs**
/// - `input_frame` (Frame) — greyscale image.
///
/// **Parameters**
/// - `r_min`              Int    (default  20)  — minimum circle radius (pixels).
/// - `r_max`              Int    (default 150)  — maximum circle radius (pixels).
/// - `edge_threshold`     Double (default  1.5) — edge threshold: sigma multiplier above the
///                                                mean Sobel magnitude of the crop.
///                                                threshold = mean(|∇|) + k × σ(|∇|).
/// - `nms_radius`         Int    (default   5)  — non-maximum suppression radius in accumulator.
/// - `min_votes`          Int    (default  20)  — minimum accumulator votes for a valid peak.
/// - `max_donuts`         Int    (default  50)  — maximum donuts to return.
/// - `margin`             Int    (default  20)  — extra pixels around r_max in crop.
/// - `max_crop_memory_mb` Int    (default 256)  — skip crops that would require more memory.
/// - `blob_stride`        Int    (default   4)  — coarse scan stride for blob detection.
/// - `blob_threshold_k`   Double (default  3.0) — blob threshold: k σ above mean pixel value.
///
/// **Outputs**
/// - `donuts`        (TableData) — one row per detected donut.
/// - `hough_summary` (TableData) — one summary row.
public struct HoughCircleProcessor: Processor {

    public var id: String { "hough_circles" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        let rMin              = parameters["r_min"]?.intValue               ?? 20
        let rMax              = parameters["r_max"]?.intValue               ?? 150
        let edgeThresholdK    = Float(parameters["edge_threshold"]?.doubleValue ?? 0.5)
        let nmsRadius         = parameters["nms_radius"]?.intValue          ?? 5
        let minVotes          = parameters["min_votes"]?.intValue           ?? 10
        let maxDonuts         = parameters["max_donuts"]?.intValue          ?? 50
        let margin            = parameters["margin"]?.intValue              ?? 20
        let maxCropMemMB      = parameters["max_crop_memory_mb"]?.intValue  ?? 256
        let blobStride        = parameters["blob_stride"]?.intValue         ?? 4
        let blobThresholdK    = parameters["blob_threshold_k"]?.doubleValue ?? 3.0

        guard rMin > 0, rMax >= rMin else {
            throw ProcessorExecutionError.executionFailed("r_min must be > 0 and r_max >= r_min")
        }

        let houghLogMsg = "HoughCircleProcessor: r_min=\(rMin) r_max=\(rMax) image \(inputTexture.width)×\(inputTexture.height)"
        Logger.processor.debug("\(houghLogMsg)")

        // Step 1: find candidate positions — prefer star_positions table from CC, fall back to blob scan
        let candidates: [CandidatePos]
        if let posTable = inputs["star_positions"] as? TableData,
           let df = posTable.dataFrame {
            candidates = extractCandidatesFromTable(df, rMax: rMax, rMin: rMin, margin: margin,
                                                    imageWidth: inputTexture.width,
                                                    imageHeight: inputTexture.height)
            Logger.processor.debug("HoughCircleProcessor: using \(candidates.count) candidates from star_positions table")
        } else {
            candidates = findBlobCandidates(
                texture: inputTexture,
                stride: blobStride,
                thresholdK: blobThresholdK,
                rMax: rMax,
                margin: margin
            )
        }

        Logger.processor.debug("HoughCircleProcessor: \(candidates.count) candidates")

        // Step 2: per-candidate Hough
        var allCircles: [DetectedCircle] = []

        for candidate in candidates {
            guard allCircles.filter({ c in
                abs(c.cx - Double(candidate.x)) < Double(rMax) &&
                abs(c.cy - Double(candidate.y)) < Double(rMax)
            }).count < 2 else { continue }   // already have circles near this candidate

            let circles = try runHoughOnCrop(
                inputTexture: inputTexture,
                candidateX: candidate.x,
                candidateY: candidate.y,
                rMin: rMin, rMax: rMax,
                edgeThresholdK: edgeThresholdK,
                nmsRadius: nmsRadius,
                minVotes: minVotes,
                margin: margin,
                maxCropMemMB: maxCropMemMB,
                device: device,
                commandQueue: commandQueue
            )
            allCircles.append(contentsOf: circles)
        }

        // Deduplicate circles across radius slices and across crops.
        // Two circles represent the same physical ring if their centers are within r_min/2 pixels —
        // that tolerance is large enough to absorb crop-to-crop position jitter.
        let dedupedCircles = deduplicateCircles(allCircles, centerTolerance: Double(rMin) / 2.0)

        Logger.processor.debug("HoughCircleProcessor: \(allCircles.count) circles before pairing (\(dedupedCircles.count) after cross-radius dedup)")
        for c in dedupedCircles {
            let msg = String(format: "  circle: cx=%.1f cy=%.1f r=%.1f votes=%d", c.cx, c.cy, c.radius, c.votes)
            Logger.processor.debug("\(msg)")
        }

        // Step 3: pair outer + inner circles into donuts
        var donuts = pairDonuts(circles: dedupedCircles, maxDonuts: maxDonuts)

        // Step 4: deduplicate donuts — keep only the highest-voted pair per spatial location.
        // Multiple crops near the same star can independently find the same donut.
        donuts = deduplicateDonuts(donuts, centerTolerance: Double(rMin))

        Logger.processor.info("HoughCircleProcessor: \(donuts.count) donuts detected")

        try writeDonutsTable(outputs: &outputs, donuts: donuts)
        try writeSummaryTable(outputs: &outputs, donuts: donuts)
    }

    // MARK: - Blob Candidate Detection

    private struct CandidatePos { let x: Int; let y: Int }

    /// Converts a connected-components pixel_coordinates table into candidate positions.
    /// Filters by minimum blob area to exclude noise fragments, then clamps positions
    /// to ensure full crops fit inside the image.
    private func extractCandidatesFromTable(
        _ df: DataFrame,
        rMax: Int,
        rMin: Int,
        margin: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> [CandidatePos] {
        guard let cxCol = df["centroid_x"] as? AnyColumn,
              let cyCol = df["centroid_y"] as? AnyColumn else { return [] }

        let areaCol = df["area"] as? AnyColumn

        // Minimum area: a filled circle at r_min has area π*r_min². Use half that as floor
        // to also catch ring-only blobs (the donut ring is thinner than a filled disc).
        let minArea = Double.pi * Double(rMin) * Double(rMin) * 0.5

        let cropHalf = rMax + margin
        var candidates: [CandidatePos] = []
        for i in 0..<df.rows.count {
            // Filter out tiny noise fragments
            if let areaCol = areaCol, let area = areaCol[i] as? Int {
                guard Double(area) >= minArea else { continue }
            }

            guard let cx = cxCol[i] as? Double,
                  let cy = cyCol[i] as? Double else { continue }
            let x = Int(cx.rounded())
            let y = Int(cy.rounded())
            // Skip positions where the crop would extend outside the image
            guard x >= cropHalf, y >= cropHalf,
                  x < imageWidth - cropHalf,
                  y < imageHeight - cropHalf else { continue }
            candidates.append(CandidatePos(x: x, y: y))
        }

        let filterMsg = "HoughCircleProcessor: \(candidates.count)/\(df.rows.count) blobs passed area filter (min area: \(Int(minArea)) px²)"
        Logger.processor.debug("\(filterMsg)")
        return candidates
    }

    /// Reads the Metal texture on the CPU to find coarse bright-blob positions.
    /// Returns deduplicated candidate centres.
    private func findBlobCandidates(
        texture: MTLTexture,
        stride: Int,
        thresholdK: Double,
        rMax: Int,
        margin: Int
    ) -> [CandidatePos] {
        let W = texture.width, H = texture.height
        let bytesPerRow = W * MemoryLayout<Float>.stride

        // Read texture into a Float array (assumes r32Float or rgba32Float)
        var pixels = [Float](repeating: 0, count: W * H)
        texture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, W, H),
            mipmapLevel: 0
        )

        // Compute mean and stddev of sampled pixels (sigma-based threshold)
        let stride2 = max(1, stride)
        var sum = 0.0
        var count = 0
        for y in Swift.stride(from: 0, to: H, by: stride2) {
            for x in Swift.stride(from: 0, to: W, by: stride2) {
                sum += Double(pixels[y * W + x])
                count += 1
            }
        }
        let mean = count > 0 ? sum / Double(count) : 0.0
        var sumSq = 0.0
        for y in Swift.stride(from: 0, to: H, by: stride2) {
            for x in Swift.stride(from: 0, to: W, by: stride2) {
                let d = Double(pixels[y * W + x]) - mean
                sumSq += d * d
            }
        }
        let stddev = count > 1 ? sqrt(sumSq / Double(count)) : 0.0
        // threshold = mean + k × σ — works correctly regardless of image normalisation
        let threshold = Float(mean + thresholdK * stddev)
        let threshMsg = String(format: "HoughCircleProcessor: blob threshold %.4f (mean=%.4f σ=%.4f k=%.1f)", Double(threshold), mean, stddev, thresholdK)
        Logger.processor.debug("\(threshMsg)")

        // Collect hot pixels
        var hot: [CandidatePos] = []
        let cropHalf = rMax + margin
        for y in Swift.stride(from: cropHalf, to: H - cropHalf, by: stride2) {
            for x in Swift.stride(from: cropHalf, to: W - cropHalf, by: stride2) {
                if pixels[y * W + x] > threshold {
                    hot.append(CandidatePos(x: x, y: y))
                }
            }
        }

        // Deduplicate: keep one representative per cluster (min-dist = 2*rMax)
        var deduped: [CandidatePos] = []
        let minDist = Double(2 * rMax)
        for pos in hot {
            let alreadyCovered = deduped.contains { p in
                let dx = Double(pos.x - p.x), dy = Double(pos.y - p.y)
                return sqrt(dx * dx + dy * dy) < minDist
            }
            if !alreadyCovered {
                deduped.append(pos)
            }
        }
        return deduped
    }

    // MARK: - Per-Crop Hough

    private struct DetectedCircle {
        let cx: Double     // centre X in full-image coordinates
        let cy: Double     // centre Y in full-image coordinates
        let radius: Double
        let votes: Int
    }

    private struct GPUHoughParams {
        var rMin: Int32
        var rMax: Int32
        var width: Int32
        var height: Int32
        var edgeThreshold: Float
    }

    private func runHoughOnCrop(
        inputTexture: MTLTexture,
        candidateX: Int,
        candidateY: Int,
        rMin: Int,
        rMax: Int,
        edgeThresholdK: Float,
        nmsRadius: Int,
        minVotes: Int,
        margin: Int,
        maxCropMemMB: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [DetectedCircle] {
        let cropHalf = rMax + margin
        let W = inputTexture.width, H = inputTexture.height

        let cropX0 = max(0, candidateX - cropHalf)
        let cropY0 = max(0, candidateY - cropHalf)
        let cropX1 = min(W, candidateX + cropHalf)
        let cropY1 = min(H, candidateY + cropHalf)
        let cropW = cropX1 - cropX0
        let cropH = cropY1 - cropY0
        guard cropW > 0, cropH > 0 else { return [] }

        let numRadii = rMax - rMin + 1
        let accBytes = numRadii * cropW * cropH * MemoryLayout<Int32>.stride
        guard accBytes <= maxCropMemMB * 1024 * 1024 else {
            let skipMsg = "HoughCircleProcessor: skipping candidate at (\(candidateX),\(candidateY)) — crop requires \(accBytes / (1024*1024)) MB > \(maxCropMemMB) MB limit"
            Logger.processor.warning("\(skipMsg)")
            return []
        }

        // 1. Blit crop to a new texture
        let cropTexture = try makeCropTexture(
            from: inputTexture,
            x0: cropX0, y0: cropY0, width: cropW, height: cropH,
            device: device,
            commandQueue: commandQueue
        )

        // 2. Gradient textures
        let gradMagTex   = try makeRGBATexture(width: cropW, height: cropH, device: device)
        let gradAngTex   = try makeRGBATexture(width: cropW, height: cropH, device: device)

        try dispatchSobelGradient(
            input: cropTexture, magOut: gradMagTex, angOut: gradAngTex,
            device: device, commandQueue: commandQueue
        )

        // Compute adaptive edge threshold from actual Sobel gradient magnitudes of this crop.
        // threshold = mean(|∇|) + edgeThresholdK × σ(|∇|)
        // This is scale-invariant and works regardless of whether the image is normalised.
        let edgeThreshold = computeAdaptiveEdgeThreshold(
            gradMagTex: gradMagTex,
            sigmaK: edgeThresholdK
        )
        let edgeMsg = String(format: "HoughCircleProcessor: crop (%d,%d) edge threshold %.4f (k=%.1f)",
                             candidateX, candidateY, edgeThreshold, edgeThresholdK)
        Logger.processor.debug("\(edgeMsg)")

        // 3. Accumulator buffer (zero-initialised via calloc-like memset)
        guard let accBuffer = device.makeBuffer(
            length: accBytes,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not allocate Hough accumulator buffer")
        }
        memset(accBuffer.contents(), 0, accBytes)

        // 4. Hough vote
        var params = GPUHoughParams(
            rMin: Int32(rMin), rMax: Int32(rMax),
            width: Int32(cropW), height: Int32(cropH),
            edgeThreshold: edgeThreshold
        )

        guard let paramsBuffer = device.makeBuffer(
            bytes: &params,
            length: MemoryLayout<GPUHoughParams>.size,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create HoughParams buffer")
        }

        try dispatchHoughVote(
            gradMag: gradMagTex, gradAng: gradAngTex,
            accumulator: accBuffer, paramsBuffer: paramsBuffer,
            cropW: cropW, cropH: cropH,
            device: device, commandQueue: commandQueue
        )

        // 5. CPU peak finding with NMS
        let accPointer = accBuffer.contents().bindMemory(to: Int32.self, capacity: numRadii * cropW * cropH)
        var circles: [DetectedCircle] = []

        for rIdx in 0..<numRadii {
            let r = rMin + rIdx
            let sliceOffset = rIdx * cropW * cropH
            // Find peaks in this radius slice using sliding-window NMS
            let peaks = findPeaks(
                slice: accPointer + sliceOffset,
                width: cropW, height: cropH,
                nmsRadius: nmsRadius,
                minVotes: minVotes
            )
            for (lx, ly, votes) in peaks {
                // Convert local crop coordinates back to full-image coordinates
                let gx = Double(cropX0 + lx)
                let gy = Double(cropY0 + ly)
                circles.append(DetectedCircle(cx: gx, cy: gy, radius: Double(r), votes: votes))
            }
        }

        return circles
    }

    // MARK: - Texture / Buffer Helpers

    private func makeCropTexture(
        from source: MTLTexture,
        x0: Int, y0: Int, width: Int, height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let desc = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: source.pixelFormat,
            width: width,
            height: height
        )
        let dest = try ProcessorHelpers.createTexture(descriptor: desc, device: device)

        let commandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create blit encoder")
        }
        blit.copy(
            from: source,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOriginMake(x0, y0, 0),
            sourceSize: MTLSizeMake(width, height, 1),
            to: dest,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blit.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(commandBuffer)
        return dest
    }

    private func makeRGBATexture(width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        let desc = ProcessorHelpers.createTextureDescriptor(
            pixelFormat: .r32Float, width: width, height: height
        )
        return try ProcessorHelpers.createTexture(descriptor: desc, device: device)
    }

    // MARK: - Adaptive Edge Threshold

    /// Reads the Sobel gradient magnitude texture (r32Float) back to the CPU and
    /// computes an adaptive threshold: mean(|∇|) + sigmaK × σ(|∇|).
    /// This is scale-invariant and works correctly for both normalised [0,1] images
    /// and raw FITS ADU images.
    private func computeAdaptiveEdgeThreshold(gradMagTex: MTLTexture, sigmaK: Float) -> Float {
        let W = gradMagTex.width, H = gradMagTex.height
        var pixels = [Float](repeating: 0, count: W * H)
        gradMagTex.getBytes(
            &pixels,
            bytesPerRow: W * MemoryLayout<Float>.stride,
            from: MTLRegionMake2D(0, 0, W, H),
            mipmapLevel: 0
        )

        var sum = 0.0
        for v in pixels { sum += Double(v) }
        let mean = sum / Double(pixels.count)

        var sumSq = 0.0
        for v in pixels {
            let d = Double(v) - mean
            sumSq += d * d
        }
        let stddev = sqrt(sumSq / Double(pixels.count))

        // Guard against degenerate case (e.g. uniform crop)
        let threshold = Float(mean + Double(sigmaK) * stddev)
        return max(threshold, 1e-6)
    }

    // MARK: - GPU Dispatch Helpers

    private func dispatchSobelGradient(
        input: MTLTexture,
        magOut: MTLTexture,
        angOut: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let fn = library.makeFunction(name: "sobel_gradient") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load sobel_gradient function")
        }
        let pso = try ProcessorHelpers.createComputePipelineState(function: fn, device: device)

        let cb = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb)

        enc.setComputePipelineState(pso)
        enc.setTexture(input,  index: 0)
        enc.setTexture(magOut, index: 1)
        enc.setTexture(angOut, index: 2)

        let (tgSize, tgCount) = ProcessorHelpers.calculateThreadgroups(for: input)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb)
    }

    private func dispatchHoughVote(
        gradMag: MTLTexture,
        gradAng: MTLTexture,
        accumulator: MTLBuffer,
        paramsBuffer: MTLBuffer,
        cropW: Int,
        cropH: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)
        guard let fn = library.makeFunction(name: "hough_vote") else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not load hough_vote function")
        }
        let pso = try ProcessorHelpers.createComputePipelineState(function: fn, device: device)

        let cb = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let enc = try ProcessorHelpers.createComputeEncoder(commandBuffer: cb)

        enc.setComputePipelineState(pso)
        enc.setTexture(gradMag, index: 0)
        enc.setTexture(gradAng, index: 1)
        enc.setBuffer(accumulator,  offset: 0, index: 0)
        enc.setBuffer(paramsBuffer, offset: 0, index: 1)

        let (tgSize, tgCount) = ProcessorHelpers.calculateThreadgroups(for: gradMag)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        try ProcessorHelpers.executeCommandBuffer(cb)
    }

    // MARK: - Peak Finding (CPU)

    /// Scans a 2-D accumulator slice for local maxima using a brute-force NMS window.
    /// Returns list of (localX, localY, votes).
    private func findPeaks(
        slice: UnsafePointer<Int32>,
        width: Int,
        height: Int,
        nmsRadius: Int,
        minVotes: Int
    ) -> [(Int, Int, Int)] {
        var peaks: [(Int, Int, Int)] = []

        for y in 0..<height {
            for x in 0..<width {
                let v = Int(slice[y * width + x])
                guard v >= minVotes else { continue }

                // Check if local maximum within nmsRadius
                var isMax = true
                outerLoop: for dy in -nmsRadius...nmsRadius {
                    for dx in -nmsRadius...nmsRadius {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                        if Int(slice[ny * width + nx]) > v {
                            isMax = false
                            break outerLoop
                        }
                    }
                }
                if isMax { peaks.append((x, y, v)) }
            }
        }

        return peaks
    }

    // MARK: - Cross-Radius Deduplication

    /// Merges circles that have similar centres across different radius slices.
    /// When the same ring produces peaks at r, r+1, r+2 etc., keep only the one
    /// with the highest vote count.
    private func deduplicateCircles(_ circles: [DetectedCircle], centerTolerance: Double) -> [DetectedCircle] {
        let sorted = circles.sorted { $0.votes > $1.votes }
        var kept: [DetectedCircle] = []
        for circle in sorted {
            let isDuplicate = kept.contains { k in
                let dx = circle.cx - k.cx
                let dy = circle.cy - k.cy
                return sqrt(dx*dx + dy*dy) < centerTolerance
            }
            if !isDuplicate { kept.append(circle) }
        }
        return kept
    }

    /// Removes duplicate donuts that share the same outer circle centre.
    /// Keeps the pair with the highest combined vote count.
    private func deduplicateDonuts(_ donuts: [DonutPair], centerTolerance: Double) -> [DonutPair] {
        let sorted = donuts.sorted { ($0.outerVotes + $0.innerVotes) > ($1.outerVotes + $1.innerVotes) }
        var kept: [DonutPair] = []
        for donut in sorted {
            let isDuplicate = kept.contains { k in
                let dx = donut.outerCX - k.outerCX
                let dy = donut.outerCY - k.outerCY
                return sqrt(dx*dx + dy*dy) < centerTolerance
            }
            if !isDuplicate { kept.append(donut) }
        }
        let dedupMsg = "HoughCircleProcessor: \(donuts.count) donuts → \(kept.count) after spatial dedup"
        Logger.processor.debug("\(dedupMsg)")
        return kept
    }

    // MARK: - Donut Pairing

    private struct DonutPair {
        let outerCX: Double, outerCY: Double, outerR: Double, outerVotes: Int
        let innerCX: Double, innerCY: Double, innerR: Double, innerVotes: Int
    }

    /// Pairs detected circles into donut (outer+inner) pairs.
    /// An inner circle must have:
    ///   r_inner < 0.7 * r_outer
    ///   |centre_inner - centre_outer| < 0.3 * r_outer
    private func pairDonuts(circles: [DetectedCircle], maxDonuts: Int) -> [DonutPair] {
        // Sort by votes descending, prefer larger circles as outer candidates
        let sorted = circles.sorted { $0.votes > $1.votes }
        var used = Set<Int>()
        var donuts: [DonutPair] = []

        for (i, outer) in sorted.enumerated() {
            guard !used.contains(i) else { continue }

            var bestInner: (index: Int, circle: DetectedCircle)?

            for (j, inner) in sorted.enumerated() {
                guard !used.contains(j), j != i else { continue }
                guard inner.radius < outer.radius * 0.75,
                      inner.radius > outer.radius * 0.1 else { continue }

                let dx = inner.cx - outer.cx
                let dy = inner.cy - outer.cy
                let dist = sqrt(dx * dx + dy * dy)
                guard dist < outer.radius * 0.35 else { continue }

                if bestInner == nil || inner.votes > bestInner!.circle.votes {
                    bestInner = (index: j, circle: inner)
                }
            }

            if let best = bestInner {
                used.insert(i)
                used.insert(best.index)
                donuts.append(DonutPair(
                    outerCX: outer.cx, outerCY: outer.cy,
                    outerR: outer.radius, outerVotes: outer.votes,
                    innerCX: best.circle.cx, innerCY: best.circle.cy,
                    innerR: best.circle.radius, innerVotes: best.circle.votes
                ))
                if donuts.count >= maxDonuts { break }
            }
        }

        return donuts
    }

    // MARK: - Output Writing

    private func writeDonutsTable(
        outputs: inout [String: ProcessData],
        donuts: [DonutPair]
    ) throws {
        guard var table = outputs["donuts"] as? TableData else { return }

        let n = donuts.count
        var df = DataFrame()
        df.append(column: Column(name: "id",           contents: Array(0..<n)))
        df.append(column: Column(name: "outer_cx",     contents: donuts.map(\.outerCX)))
        df.append(column: Column(name: "outer_cy",     contents: donuts.map(\.outerCY)))
        df.append(column: Column(name: "outer_r",      contents: donuts.map(\.outerR)))
        df.append(column: Column(name: "outer_votes",  contents: donuts.map(\.outerVotes)))
        df.append(column: Column(name: "inner_cx",     contents: donuts.map(\.innerCX)))
        df.append(column: Column(name: "inner_cy",     contents: donuts.map(\.innerCY)))
        df.append(column: Column(name: "inner_r",      contents: donuts.map(\.innerR)))
        df.append(column: Column(name: "inner_votes",  contents: donuts.map(\.innerVotes)))
        df.append(column: Column(name: "offset_x",     contents: donuts.map { $0.innerCX - $0.outerCX }))
        df.append(column: Column(name: "offset_y",     contents: donuts.map { $0.innerCY - $0.outerCY }))
        df.append(column: Column(name: "offset_magnitude", contents: donuts.map { d in
            let dx = d.innerCX - d.outerCX, dy = d.innerCY - d.outerCY
            return sqrt(dx * dx + dy * dy)
        }))
        df.append(column: Column(name: "offset_angle", contents: donuts.map { d in
            atan2(d.innerCY - d.outerCY, d.innerCX - d.outerCX)
        }))
        df.append(column: Column(name: "r_ratio",      contents: donuts.map { $0.innerR / $0.outerR }))

        table.dataFrame = df
        outputs["donuts"] = table
    }

    private func writeSummaryTable(
        outputs: inout [String: ProcessData],
        donuts: [DonutPair]
    ) throws {
        guard var table = outputs["hough_summary"] as? TableData else { return }

        let offsets = donuts.map { d -> Double in
            let dx = d.innerCX - d.outerCX, dy = d.innerCY - d.outerCY
            return sqrt(dx * dx + dy * dy)
        }
        let meanOffX = donuts.isEmpty ? 0.0 : donuts.map { $0.innerCX - $0.outerCX }.reduce(0, +) / Double(donuts.count)
        let meanOffY = donuts.isEmpty ? 0.0 : donuts.map { $0.innerCY - $0.outerCY }.reduce(0, +) / Double(donuts.count)
        let medianOffset = offsets.isEmpty ? 0.0 : calculateMedian(offsets)

        let n = Double(offsets.count)
        let meanOff = offsets.isEmpty ? 0.0 : offsets.reduce(0, +) / n
        let stdOff: Double
        if offsets.count > 1 {
            let varOff = offsets.map { ($0 - meanOff) * ($0 - meanOff) }.reduce(0, +) / n
            stdOff = sqrt(max(0, varOff))
        } else {
            stdOff = 0.0
        }

        var df = DataFrame()
        df.append(column: Column(name: "donut_count",           contents: [donuts.count]))
        df.append(column: Column(name: "median_offset_magnitude", contents: [medianOffset]))
        df.append(column: Column(name: "mean_offset_x",         contents: [meanOffX]))
        df.append(column: Column(name: "mean_offset_y",         contents: [meanOffY]))
        df.append(column: Column(name: "offset_stddev",         contents: [stdOff]))

        table.dataFrame = df
        outputs["hough_summary"] = table
    }

    private func calculateMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}
