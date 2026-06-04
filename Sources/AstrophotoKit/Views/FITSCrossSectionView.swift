import SwiftUI
import Charts
import Metal

private struct CrossSectionPoint: Identifiable {
    let id: UUID = UUID()
    let position: Float
    let intensity: Float
    let series: String
}

/// Displays intensity cross-sections along the horizontal and vertical centre axes of a FITS image.
@available(iOS 16.0, macOS 13.0, *)
public struct FITSCrossSectionView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureMinValue: Float
    let textureMaxValue: Float

    public init(fitsImage: FITSImage? = nil, texture: MTLTexture? = nil, textureMinValue: Float = 0.0, textureMaxValue: Float = 1.0) {
        self.fitsImage = fitsImage
        self.texture = texture
        self.textureMinValue = textureMinValue
        self.textureMaxValue = textureMaxValue
    }

    public var body: some View {
        if fitsImage != nil || texture != nil {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    ForEach(Array(xSection().enumerated()), id: \.offset) { index, intensity in
                        LineMark(x: .value("Position", Float(index)), y: .value("Intensity", intensity))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(by: .value("Series", "X-axis"))

                    ForEach(Array(ySection().enumerated()), id: \.offset) { index, intensity in
                        LineMark(x: .value("Position", Float(index)), y: .value("Intensity", intensity))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(by: .value("Series", "Y-axis"))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisGridLine(); AxisTick()
                        if let d = value.as(Double.self) { AxisValueLabel(String(format: "%.0f", d)) }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic) { _ in AxisGridLine(); AxisTick(); AxisValueLabel() }
                }
                .chartXAxisLabel("Pixel Position")
                .chartYAxisLabel("Intensity")
                .chartLegend {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) { Circle().fill(.blue).frame(width: 8, height: 8);  Text("X-axis").font(.caption) }
                        HStack(spacing: 4) { Circle().fill(.green).frame(width: 8, height: 8); Text("Y-axis").font(.caption) }
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("No cross-section data")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func xSection() -> [Float] {
        if let img = fitsImage  { return img.getCenterXCrossSection() }
        if let tex = texture    { return textureCenterRow(tex) }
        return []
    }

    private func ySection() -> [Float] {
        if let img = fitsImage  { return img.getCenterYCrossSection() }
        if let tex = texture    { return textureCenterColumn(tex) }
        return []
    }

    private func textureCenterRow(_ texture: MTLTexture) -> [Float] {
        let w = texture.width, h = texture.height
        let centerY = h / 2
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return [] }

        let isRGBA = isRGBAFormat(texture.pixelFormat)
        let bpp = isRGBA ? MemoryLayout<Float32>.size * 4 : MemoryLayout<Float32>.size
        let alignedBPR = ((w * bpp + 15) / 16) * 16

        guard let buf  = device.makeBuffer(length: alignedBPR, options: .storageModeShared),
              let cmd  = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return [] }

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: centerY, z: 0),
                  sourceSize: MTLSize(width: w, height: 1, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: alignedBPR, destinationBytesPerImage: alignedBPR)
        blit.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.error == nil else { return [] }

        let ptr = buf.contents().bindMemory(to: Float32.self, capacity: isRGBA ? w * 4 : w)
        let range = textureMaxValue - textureMinValue
        return (0..<w).map { x in
            let norm = isRGBA ? ptr[x * 4] : ptr[x]
            return textureMinValue + norm * range
        }
    }

    private func textureCenterColumn(_ texture: MTLTexture) -> [Float] {
        let w = texture.width, h = texture.height
        let centerX = w / 2
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return [] }

        let isRGBA = isRGBAFormat(texture.pixelFormat)
        let bpp = isRGBA ? MemoryLayout<Float32>.size * 4 : MemoryLayout<Float32>.size
        let alignedBPR = ((w * bpp + 15) / 16) * 16
        let bufSize = alignedBPR * h

        guard let buf  = device.makeBuffer(length: bufSize, options: .storageModeShared),
              let cmd  = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return [] }

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: alignedBPR, destinationBytesPerImage: bufSize)
        blit.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.error == nil else { return [] }

        let stride = alignedBPR / MemoryLayout<Float32>.size
        let ptr = buf.contents().bindMemory(to: Float32.self, capacity: isRGBA ? w * h * 4 : w * h)
        let range = textureMaxValue - textureMinValue
        return (0..<h).map { y in
            let idx = y * stride + (isRGBA ? centerX * 4 : centerX)
            return textureMinValue + ptr[idx] * range
        }
    }

    private func isRGBAFormat(_ format: MTLPixelFormat) -> Bool {
        format == .rgba32Float || format == .rgba16Float || format == .rgba8Unorm
    }
}
