import Accelerate
import Metal

/// Internal Metal texture readback helper, shared by FITSImageToolsView and FITSCrossSectionView.
/// Centralises pixel format detection, buffer allocation, and denormalization so the two call sites
/// can't drift independently.
struct FITSTextureReader {
    let texture: MTLTexture
    let minValue: Float
    let maxValue: Float

    /// Read a single pixel at (x, y) and return its denormalized value.
    /// Returns nil when coordinates are out of bounds or the GPU read fails.
    func readPixel(x: Int, y: Int) -> Float? {
        guard x >= 0 && x < texture.width && y >= 0 && y < texture.height else { return nil }
        guard let (device, queue) = metalResources else { return nil }

        let bufSize = isRGBA ? 16 : max(16, MemoryLayout<Float32>.size)
        guard let buf  = device.makeBuffer(length: bufSize, options: .storageModeShared),
              let cmd  = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bufSize, destinationBytesPerImage: bufSize)
        blit.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.error == nil else { return nil }

        let ptr = buf.contents().bindMemory(to: Float32.self, capacity: isRGBA ? 4 : 1)
        return denormalize(ptr[0])
    }

    /// Dispatch a 1D compute kernel (cross_section_row or cross_section_column) and return
    /// the denormalized float array. Returns an empty array on any failure.
    func readSection(pipeline: MTLComputePipelineState?, count: Int, coord: UInt32) -> [Float] {
        guard let (device, queue) = metalResources,
              let pipeline else { return [] }

        let bufSize = count * MemoryLayout<Float>.size
        guard let outBuf = device.makeBuffer(length: bufSize, options: .storageModeShared),
              let cmd     = queue.makeCommandBuffer(),
              let enc     = cmd.makeComputeCommandEncoder() else { return [] }

        var coordVal = coord
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 0)
        enc.setBytes(&coordVal, length: MemoryLayout<UInt32>.size, index: 1)

        let tgSize  = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let tgCount = (count + tgSize - 1) / tgSize
        enc.dispatchThreadgroups(MTLSize(width: tgCount, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tgSize, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.error == nil else { return [] }

        // Denormalize the entire output buffer in one SIMD pass: result = ptr * range + minValue
        var result = [Float](repeating: 0, count: count)
        var scale  = maxValue - minValue
        var bias   = minValue
        let ptr    = outBuf.contents().bindMemory(to: Float.self, capacity: count)
        vDSP_vsmsa(ptr, 1, &scale, &bias, &result, 1, vDSP_Length(count))
        return result
    }

    // MARK: - Private

    private var metalResources: (MTLDevice, MTLCommandQueue)? {
        guard let d = MetalShared.device, let q = MetalShared.queue else { return nil }
        return (d, q)
    }

    private var isRGBA: Bool {
        // Only rgba32Float is safe to read via Float32 blit (16 bytes per pixel).
        // rgba16Float (8 bytes) and rgba8Unorm (4 bytes) require different buffer sizes
        // and can't be interpreted as Float32 directly. Neither is produced by FITSImageView.
        texture.pixelFormat == .rgba32Float
    }

    private func denormalize(_ value: Float) -> Float {
        minValue + value * (maxValue - minValue)
    }
}
