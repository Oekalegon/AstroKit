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
        computeCrossSection(texture: texture,
                            pipeline: MetalShared.crossSectionRowPipeline,
                            count: texture.width,
                            coord: UInt32(texture.height / 2))
    }

    private func textureCenterColumn(_ texture: MTLTexture) -> [Float] {
        computeCrossSection(texture: texture,
                            pipeline: MetalShared.crossSectionColumnPipeline,
                            count: texture.height,
                            coord: UInt32(texture.width / 2))
    }

    /// Dispatches a 1D compute kernel that reads one row or column from `texture` into a float buffer,
    /// then denormalizes the results back into the original value range.
    private func computeCrossSection(
        texture: MTLTexture,
        pipeline: MTLComputePipelineState?,
        count: Int,
        coord: UInt32
    ) -> [Float] {
        guard let device   = MetalShared.device,
              let queue    = MetalShared.queue,
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

        let ptr   = outBuf.contents().bindMemory(to: Float.self, capacity: count)
        let range = textureMaxValue - textureMinValue
        return (0..<count).map { textureMinValue + ptr[$0] * range }
    }
}
