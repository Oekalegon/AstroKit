import SwiftUI
import Charts
import Metal

/// Displays intensity cross-sections along the horizontal and vertical centre axes of a FITS image.
@available(iOS 16.0, macOS 13.0, *)
public struct FITSCrossSectionView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureMinValue: Float
    let textureMaxValue: Float
    /// Stable caller-supplied identifier for the image content.
    /// When provided, cross-sections recompute whenever this value changes, which correctly
    /// distinguishes two FITSImage values that share the same dimensions and value range.
    /// When nil the ID falls back to width/height/min/max, which may miss same-sized swaps.
    let imageID: String?

    @State private var xData: [Float] = []
    @State private var yData: [Float] = []

    public init(fitsImage: FITSImage? = nil, texture: MTLTexture? = nil, textureMinValue: Float = 0.0, textureMaxValue: Float = 1.0, imageID: String? = nil) {
        self.fitsImage = fitsImage
        self.texture = texture
        self.textureMinValue = textureMinValue
        self.textureMaxValue = textureMaxValue
        self.imageID = imageID
    }

    public var body: some View {
        if fitsImage != nil || texture != nil {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    ForEach(Array(xData.enumerated()), id: \.offset) { index, intensity in
                        LineMark(x: .value("Position", Float(index)), y: .value("Intensity", intensity))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }

                    ForEach(Array(yData.enumerated()), id: \.offset) { index, intensity in
                        LineMark(x: .value("Position", Float(index)), y: .value("Intensity", intensity))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
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
                        HStack(spacing: 4) { Rectangle().fill(.blue).frame(width: 16, height: 2);  Text("X-axis").font(.caption) }
                        HStack(spacing: 4) { Rectangle().fill(.green).frame(width: 16, height: 2); Text("Y-axis").font(.caption) }
                    }
                }
            }
            .padding(.vertical, 4)
            .task(id: sourceID) {
                // Capture value-type copies so Task.detached doesn't need self.
                let img  = fitsImage
                let tex  = texture
                let minV = textureMinValue
                let maxV = textureMaxValue
                let (x, y) = await Task.detached(priority: .userInitiated) {
                    var xResult = [Float]()
                    var yResult = [Float]()
                    if let img {
                        xResult = img.getCenterXCrossSection()
                        yResult = img.getCenterYCrossSection()
                    } else if let tex {
                        let reader = FITSTextureReader(texture: tex, minValue: minV, maxValue: maxV)
                        xResult = reader.readSection(pipeline: MetalShared.crossSectionRowPipeline,
                                                     count: tex.width,  coord: UInt32(tex.height / 2))
                        yResult = reader.readSection(pipeline: MetalShared.crossSectionColumnPipeline,
                                                     count: tex.height, coord: UInt32(tex.width / 2))
                    }
                    return (xResult, yResult)
                }.value
                xData = x
                yData = y
            }
        } else {
            Text("No cross-section data")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Data source identity

    /// A string that changes whenever the underlying data source changes,
    /// used as the `.task` ID to trigger recomputation.
    private var sourceID: String {
        if let tex = texture {
            return "tex-\(ObjectIdentifier(tex as AnyObject))-\(textureMinValue)-\(textureMaxValue)"
        }
        if let img = fitsImage {
            return "img-\(imageID ?? "")-\(img.width)-\(img.height)-\(img.originalMinValue)-\(img.originalMaxValue)"
        }
        return ""
    }

}
