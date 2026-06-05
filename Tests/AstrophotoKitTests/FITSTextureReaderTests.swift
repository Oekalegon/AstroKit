import Testing
@testable import AstrophotoKit
import Metal

// MARK: - Helpers

/// Create a 1-channel r32Float texture filled with `values` in row-major order.
private func makeGrayscaleTexture(width: Int, height: Int, values: [Float]) -> MTLTexture? {
    guard values.count == width * height else { return nil }
    guard let device = MetalShared.device else { return nil }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
    desc.usage       = [.shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size:   MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes:   values,
                bytesPerRow: width * MemoryLayout<Float>.size)
    return tex
}

/// Create an rgba32Float texture; `values` is [r, g, b, a, r, g, b, a, ...] row-major.
private func makeRGBATexture(width: Int, height: Int, values: [Float]) -> MTLTexture? {
    guard values.count == width * height * 4 else { return nil }
    guard let device = MetalShared.device else { return nil }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    desc.usage       = [.shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size:   MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes:   values,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size)
    return tex
}

private func approxEqual(_ a: Float, _ b: Float, tolerance: Float = 1e-5) -> Bool {
    abs(a - b) < tolerance
}

// MARK: - readPixel: bounds checking

@Suite("FITSTextureReader.readPixel — bounds")
struct FITSTextureReaderPixelBoundsTests {
    private let tex: MTLTexture? = makeGrayscaleTexture(
        width: 4, height: 4, values: Array(repeating: 0.5, count: 16))

    @Test("returns nil for x < 0")
    func negativeX() {
        guard let tex else { Issue.record("Metal unavailable"); return }
        #expect(FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: -1, y: 0) == nil)
    }

    @Test("returns nil for x == width")
    func xEqualsWidth() {
        guard let tex else { Issue.record("Metal unavailable"); return }
        #expect(FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 4, y: 0) == nil)
    }

    @Test("returns nil for y < 0")
    func negativeY() {
        guard let tex else { Issue.record("Metal unavailable"); return }
        #expect(FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 0, y: -1) == nil)
    }

    @Test("returns nil for y == height")
    func yEqualsHeight() {
        guard let tex else { Issue.record("Metal unavailable"); return }
        #expect(FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 0, y: 4) == nil)
    }

    @Test("returns non-nil at (0, 0)")
    func topLeftCorner() {
        guard let tex else { Issue.record("Metal unavailable"); return }
        #expect(FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 0, y: 0) != nil)
    }

    @Test("returns non-nil at (width-1, height-1)")
    func bottomRightCorner() {
        guard let tex else { Issue.record("Metal unavailable"); return }
        #expect(FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 3, y: 3) != nil)
    }
}

// MARK: - readPixel: grayscale correctness

@Suite("FITSTextureReader.readPixel — grayscale")
struct FITSTextureReaderPixelGrayscaleTests {

    @Test("reads correct pixel values from a 3×3 r32Float texture")
    func pixelValues() {
        let values: [Float] = [0.1, 0.2, 0.3,
                               0.4, 0.5, 0.6,
                               0.7, 0.8, 0.9]
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        let reader = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
        #expect(approxEqual(reader.readPixel(x: 0, y: 0)!, 0.1))
        #expect(approxEqual(reader.readPixel(x: 2, y: 0)!, 0.3))
        #expect(approxEqual(reader.readPixel(x: 1, y: 1)!, 0.5))
        #expect(approxEqual(reader.readPixel(x: 2, y: 2)!, 0.9))
    }

    @Test("denormalizes: stored 0.5 with min=100, max=200 → 150")
    func denormalization() {
        guard let tex = makeGrayscaleTexture(width: 1, height: 1, values: [0.5]) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 100, maxValue: 200).readPixel(x: 0, y: 0)
        #expect(approxEqual(result!, 150.0))
    }

    @Test("stored 0.0 returns minValue")
    func storedZeroReturnsMin() {
        guard let tex = makeGrayscaleTexture(width: 1, height: 1, values: [0.0]) else {
            Issue.record("Metal unavailable"); return
        }
        #expect(approxEqual(
            FITSTextureReader(texture: tex, minValue: 42, maxValue: 100).readPixel(x: 0, y: 0)!,
            42.0))
    }

    @Test("stored 1.0 returns maxValue")
    func storedOneReturnsMax() {
        guard let tex = makeGrayscaleTexture(width: 1, height: 1, values: [1.0]) else {
            Issue.record("Metal unavailable"); return
        }
        #expect(approxEqual(
            FITSTextureReader(texture: tex, minValue: 0, maxValue: 255).readPixel(x: 0, y: 0)!,
            255.0))
    }
}

// MARK: - readPixel: RGBA texture

@Suite("FITSTextureReader.readPixel — RGBA")
struct FITSTextureReaderPixelRGBATests {

    @Test("reads R channel from rgba32Float texture, ignores G/B/A")
    func readsRChannel() {
        // R=0.7, G=0.2, B=0.1, A=1.0
        guard let tex = makeRGBATexture(width: 1, height: 1, values: [0.7, 0.2, 0.1, 1.0]) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 0, y: 0)
        #expect(approxEqual(result!, 0.7))
    }

    @Test("denormalizes RGBA R channel")
    func denormalizesRGBA() {
        guard let tex = makeRGBATexture(width: 1, height: 1, values: [0.25, 0.5, 0.75, 1.0]) else {
            Issue.record("Metal unavailable"); return
        }
        // min=0, max=4 → 0.25 * 4 = 1.0
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 4).readPixel(x: 0, y: 0)
        #expect(approxEqual(result!, 1.0))
    }

    @Test("rgba32Float R channel is in valid range after denormalization")
    func rgba32FloatInRange() {
        // Regression: rgba8Unorm and rgba16Float were incorrectly treated as rgba32Float,
        // giving Float32-misinterpreted garbage values well outside [minValue, maxValue].
        guard let tex = makeRGBATexture(width: 1, height: 1, values: [0.5, 0.0, 0.0, 1.0]) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1).readPixel(x: 0, y: 0)!
        #expect(result >= 0.0 && result <= 1.0, "Expected value in [0, 1], got \(result)")
        #expect(approxEqual(result, 0.5))
    }
}

// MARK: - readSection: row shader

@Suite("FITSTextureReader.readSection — row")
struct FITSTextureReaderSectionRowTests {

    @Test("extracts the correct row from a 3×3 texture")
    func correctRowValues() {
        guard let pipeline = MetalShared.crossSectionRowPipeline else {
            Issue.record("crossSectionRowPipeline unavailable"); return
        }
        let values: [Float] = [0.0, 0.0, 0.0,   // row 0
                               0.1, 0.5, 0.9,   // row 1 (requested)
                               0.0, 0.0, 0.0]   // row 2
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: pipeline, count: 3, coord: 1)
        #expect(result.count == 3)
        #expect(approxEqual(result[0], 0.1))
        #expect(approxEqual(result[1], 0.5))
        #expect(approxEqual(result[2], 0.9))
    }

    @Test("result count equals texture width")
    func resultCountEqualsWidth() {
        guard let pipeline = MetalShared.crossSectionRowPipeline else {
            Issue.record("crossSectionRowPipeline unavailable"); return
        }
        let w = 10, h = 4
        guard let tex = makeGrayscaleTexture(width: w, height: h, values: Array(repeating: 0.5, count: w * h)) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: pipeline, count: w, coord: UInt32(h / 2))
        #expect(result.count == w)
    }

    @Test("denormalizes row values with custom min/max")
    func denormalization() {
        guard let pipeline = MetalShared.crossSectionRowPipeline else {
            Issue.record("crossSectionRowPipeline unavailable"); return
        }
        let values: [Float] = [0.0, 0.0, 0.0,
                               0.5, 0.5, 0.5,   // row 1: all 0.5
                               0.0, 0.0, 0.0]
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        // min=0, max=1000 → 0.5 * 1000 = 500
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1000)
            .readSection(pipeline: pipeline, count: 3, coord: 1)
        for val in result { #expect(approxEqual(val, 500.0, tolerance: 0.1)) }
    }
}

// MARK: - readSection: column shader

@Suite("FITSTextureReader.readSection — column")
struct FITSTextureReaderSectionColumnTests {

    @Test("extracts the correct column from a 3×3 texture")
    func correctColumnValues() {
        guard let pipeline = MetalShared.crossSectionColumnPipeline else {
            Issue.record("crossSectionColumnPipeline unavailable"); return
        }
        let values: [Float] = [0.0, 0.1, 0.0,   // row 0: col 1 = 0.1
                               0.0, 0.5, 0.0,   // row 1: col 1 = 0.5
                               0.0, 0.9, 0.0]   // row 2: col 1 = 0.9
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: pipeline, count: 3, coord: 1)
        #expect(result.count == 3)
        #expect(approxEqual(result[0], 0.1))
        #expect(approxEqual(result[1], 0.5))
        #expect(approxEqual(result[2], 0.9))
    }

    @Test("result count equals texture height")
    func resultCountEqualsHeight() {
        guard let pipeline = MetalShared.crossSectionColumnPipeline else {
            Issue.record("crossSectionColumnPipeline unavailable"); return
        }
        let w = 4, h = 10
        guard let tex = makeGrayscaleTexture(width: w, height: h, values: Array(repeating: 0.5, count: w * h)) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: pipeline, count: h, coord: UInt32(w / 2))
        #expect(result.count == h)
    }

    @Test("row and column sections are independent")
    func rowAndColumnIndependent() {
        guard let rowPipeline = MetalShared.crossSectionRowPipeline,
              let colPipeline = MetalShared.crossSectionColumnPipeline else {
            Issue.record("Pipelines unavailable"); return
        }
        // Diagonal gradient: pixel(x, y) = (x + y * 3) / 9.0
        let values: [Float] = (0..<9).map { Float($0) / 9.0 }
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        let reader = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
        let row = reader.readSection(pipeline: rowPipeline, count: 3, coord: 1)
        let col = reader.readSection(pipeline: colPipeline, count: 3, coord: 1)
        // Center row (y=1): pixels at (0,1), (1,1), (2,1) → indices 3, 4, 5 → 3/9, 4/9, 5/9
        #expect(approxEqual(row[0], 3.0/9.0))
        #expect(approxEqual(row[1], 4.0/9.0))
        #expect(approxEqual(row[2], 5.0/9.0))
        // Center column (x=1): pixels at (1,0), (1,1), (1,2) → indices 1, 4, 7 → 1/9, 4/9, 7/9
        #expect(approxEqual(col[0], 1.0/9.0))
        #expect(approxEqual(col[1], 4.0/9.0))
        #expect(approxEqual(col[2], 7.0/9.0))
    }
}

// MARK: - readSection: edge cases

@Suite("FITSTextureReader.readSection — edge cases")
struct FITSTextureReaderSectionEdgeCaseTests {

    @Test("returns empty array for nil pipeline")
    func nilPipeline() {
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: Array(repeating: 0.5, count: 9)) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: nil, count: 3, coord: 1)
        #expect(result.isEmpty)
    }

    @Test("row at y=0 reads top row")
    func firstRow() {
        guard let pipeline = MetalShared.crossSectionRowPipeline else {
            Issue.record("crossSectionRowPipeline unavailable"); return
        }
        let values: [Float] = [0.1, 0.2, 0.3,
                               0.0, 0.0, 0.0,
                               0.0, 0.0, 0.0]
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: pipeline, count: 3, coord: 0)
        #expect(approxEqual(result[0], 0.1))
        #expect(approxEqual(result[1], 0.2))
        #expect(approxEqual(result[2], 0.3))
    }

    @Test("column at x=0 reads leftmost column")
    func firstColumn() {
        guard let pipeline = MetalShared.crossSectionColumnPipeline else {
            Issue.record("crossSectionColumnPipeline unavailable"); return
        }
        let values: [Float] = [0.1, 0.0, 0.0,
                               0.4, 0.0, 0.0,
                               0.7, 0.0, 0.0]
        guard let tex = makeGrayscaleTexture(width: 3, height: 3, values: values) else {
            Issue.record("Metal unavailable"); return
        }
        let result = FITSTextureReader(texture: tex, minValue: 0, maxValue: 1)
            .readSection(pipeline: pipeline, count: 3, coord: 0)
        #expect(approxEqual(result[0], 0.1))
        #expect(approxEqual(result[1], 0.4))
        #expect(approxEqual(result[2], 0.7))
    }
}

