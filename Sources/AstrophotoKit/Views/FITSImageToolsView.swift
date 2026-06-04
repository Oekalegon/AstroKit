import SwiftUI
import Metal

/// Displays image tools: pixel information, histogram, black/white point controls, extracted region, and cross-sections.
@available(iOS 16.0, macOS 13.0, *)
public struct FITSImageToolsView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureWidth: Int
    let textureHeight: Int
    let textureMinValue: Float
    let textureMaxValue: Float
    let imageID: String?
    @Binding var blackPoint: Float
    @Binding var whitePoint: Float
    let cursorPosition: SIMD2<Float>?
    let aspectRatio: SIMD2<Float>
    let extractedRegion: FITSImage?
    let extractedRegionTexture: MTLTexture?
    @Binding var extractedRegionSize: Int
    @Binding var zoom: Float
    @Binding var panOffset: SIMD2<Float>
    let onExtractedRegionSizeChanged: ((Int) -> Void)?

    @State private var showFullRange: Bool = true
    @State private var useLogScale: Bool = false
    @State private var extractedRegionZoom: Float = 1.0
    @State private var extractedRegionPanOffset: SIMD2<Float> = SIMD2<Float>(0, 0)
    @State private var pixelSample: PixelSample? = nil

    private let regionSizes = [10, 20, 30, 40, 50]

    private struct PixelSample {
        let x: Int; let y: Int; let intensity: Float?
    }

    private struct SampleKey: Hashable {
        let cursor: SIMD2<Float>?
        let zoom: Float
        let panOffset: SIMD2<Float>
        let aspectRatio: SIMD2<Float>
        let textureHash: Int
    }

    private var sampleKey: SampleKey {
        SampleKey(
            cursor: cursorPosition,
            zoom: zoom,
            panOffset: panOffset,
            aspectRatio: aspectRatio,
            textureHash: texture.map { ObjectIdentifier($0 as AnyObject).hashValue } ?? 0
        )
    }

    public init(
        fitsImage: FITSImage? = nil,
        texture: MTLTexture? = nil,
        textureWidth: Int = 0,
        textureHeight: Int = 0,
        textureMinValue: Float = 0.0,
        textureMaxValue: Float = 1.0,
        imageID: String? = nil,
        blackPoint: Binding<Float>,
        whitePoint: Binding<Float>,
        cursorPosition: SIMD2<Float>? = nil,
        aspectRatio: SIMD2<Float> = SIMD2<Float>(1.0, 1.0),
        extractedRegion: FITSImage? = nil,
        extractedRegionTexture: MTLTexture? = nil,
        extractedRegionSize: Binding<Int> = .constant(30),
        zoom: Binding<Float> = .constant(1.0),
        panOffset: Binding<SIMD2<Float>> = .constant(SIMD2<Float>(0, 0)),
        onExtractedRegionSizeChanged: ((Int) -> Void)? = nil
    ) {
        self.fitsImage = fitsImage
        self.texture = texture
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.textureMinValue = textureMinValue
        self.textureMaxValue = textureMaxValue
        self.imageID = imageID
        self._blackPoint = blackPoint
        self._whitePoint = whitePoint
        self.cursorPosition = cursorPosition
        self.aspectRatio = aspectRatio
        self.extractedRegion = extractedRegion
        self.extractedRegionTexture = extractedRegionTexture
        self._extractedRegionSize = extractedRegionSize
        self._zoom = zoom
        self._panOffset = panOffset
        self.onExtractedRegionSizeChanged = onExtractedRegionSizeChanged
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cursorPosition != nil {
                    GroupBox("Pixel Information") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let sample = pixelSample {
                                InfoRow(label: "X", value: "\(sample.x)")
                                InfoRow(label: "Y", value: "\(sample.y)")
                                InfoRow(label: "Intensity", value: sample.intensity.map { String(format: "%.6f", $0) } ?? "N/A")
                            } else {
                                Text("Cursor outside image bounds").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if texture != nil || fitsImage != nil {
                    GroupBox("Histogram") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show Full Range", isOn: $showFullRange).font(.caption)
                            Toggle("Use Log Scale",   isOn: $useLogScale).font(.caption)
                            if let texture = texture {
                                FITSHistogramChart(
                                    texture: texture,
                                    textureMinValue: textureMinValue,
                                    textureMaxValue: textureMaxValue,
                                    imageID: imageID,
                                    numBins: nil,
                                    showNormalized: false,
                                    blackPoint: blackPoint,
                                    whitePoint: whitePoint,
                                    showFullRange: showFullRange,
                                    useLogScale: useLogScale
                                )
                            } else if let fitsImage = fitsImage {
                                FITSHistogramChart(
                                    fitsImage: fitsImage,
                                    imageID: imageID,
                                    numBins: nil,
                                    showNormalized: false,
                                    blackPoint: blackPoint,
                                    whitePoint: whitePoint,
                                    showFullRange: showFullRange,
                                    useLogScale: useLogScale
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    let minValue = texture != nil ? textureMinValue : (fitsImage?.originalMinValue ?? 0.0)
                    let maxValue = texture != nil ? textureMaxValue : (fitsImage?.originalMaxValue ?? 1.0)

                    GroupBox("Image Adjustments") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Black Point").font(.caption).frame(width: 80, alignment: .leading)
                                    Text(String(format: "%.3f", blackPoint)).font(.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                Slider(value: $blackPoint, in: minValue...whitePoint) { Text("Black Point") }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("White Point").font(.caption).frame(width: 80, alignment: .leading)
                                    Text(String(format: "%.3f", whitePoint)).font(.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                Slider(value: $whitePoint, in: blackPoint...maxValue) { Text("White Point") }
                            }
                            Button { blackPoint = minValue; whitePoint = maxValue } label: {
                                Text("Reset").font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }

                    if let extractedRegionTexture = extractedRegionTexture {
                        extractedRegionBox(texture: extractedRegionTexture, fitsImage: nil)
                        GroupBox("Cross Sections") {
                            FITSCrossSectionView(texture: extractedRegionTexture, textureMinValue: textureMinValue, textureMaxValue: textureMaxValue)
                                .frame(height: 200)
                        }
                    } else if let extractedRegion = extractedRegion {
                        extractedRegionBox(texture: nil, fitsImage: extractedRegion)
                        GroupBox("Cross Sections") {
                            FITSCrossSectionView(fitsImage: extractedRegion)
                                .frame(height: 200)
                        }
                    }
                }

                if texture == nil && fitsImage == nil {
                    Text("No image loaded")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding()
        }
        .task(id: sampleKey) {
            guard let cursor = cursorPosition else { pixelSample = nil; return }
            // Capture value-type copies so Task.detached doesn't need self.
            let tex  = texture
            let img  = fitsImage
            let w    = textureWidth
            let h    = textureHeight
            let minV = textureMinValue
            let maxV = textureMaxValue
            let z    = zoom
            let pan  = panOffset
            let ar   = aspectRatio
            let sample = await Task.detached(priority: .userInitiated) { () -> PixelSample? in
                if let tex {
                    guard let coord = FITSCoordinateConverter.screenToTextureCoord(
                        normalizedX: cursor.x, normalizedY: cursor.y,
                        zoom: z, panOffset: pan, aspectRatio: ar) else { return nil }
                    let px = Int(coord.x * Float(w))
                    let py = Int(coord.y * Float(h))
                    let intensity = FITSImageToolsView.readTexturePixel(
                        texture: tex, x: px, y: py, minValue: minV, maxValue: maxV)
                    return PixelSample(x: px, y: py, intensity: intensity)
                } else if let img {
                    guard let px = img.screenToImagePixel(
                        normalizedX: cursor.x, normalizedY: cursor.y,
                        zoom: z, panOffset: pan, aspectRatio: ar) else { return nil }
                    return PixelSample(x: px.x, y: px.y, intensity: img.getPixelValue(x: px.x, y: px.y))
                }
                return nil
            }.value
            pixelSample = sample
        }
    }

    @ViewBuilder
    private func extractedRegionBox(texture: MTLTexture?, fitsImage: FITSImage?) -> some View {
        GroupBox("Extracted Region (\(extractedRegionSize)×\(extractedRegionSize))") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Size:").font(.caption)
                    Picker("Region Size", selection: $extractedRegionSize) {
                        ForEach(regionSizes, id: \.self) { size in Text("\(size)×\(size)").tag(size) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: extractedRegionSize) { _, newSize in onExtractedRegionSizeChanged?(newSize) }
                }
                .padding(.horizontal, 4)

                if let texture = texture {
                    FITSImageView(
                        texture: texture,
                        textureMinValue: textureMinValue,
                        textureMaxValue: textureMaxValue,
                        displayMode: .normal,
                        zoom: $extractedRegionZoom,
                        panOffset: $extractedRegionPanOffset,
                        blackPoint: $blackPoint,
                        whitePoint: $whitePoint,
                        isInteractive: false
                    )
                    .frame(height: 200)
                    .onAppear { extractedRegionZoom = 1.0; extractedRegionPanOffset = .zero }
                    .onChange(of: extractedRegionSize) { _, _ in extractedRegionZoom = 1.0; extractedRegionPanOffset = .zero }
                } else if let fitsImage = fitsImage {
                    FITSImageView(
                        fitsImage: fitsImage,
                        displayMode: .normal,
                        zoom: $extractedRegionZoom,
                        panOffset: $extractedRegionPanOffset,
                        blackPoint: $blackPoint,
                        whitePoint: $whitePoint,
                        isInteractive: false
                    )
                    .frame(height: 200)
                    .onAppear { extractedRegionZoom = 1.0; extractedRegionPanOffset = .zero }
                    .onChange(of: fitsImage) { _, _ in extractedRegionZoom = 1.0; extractedRegionPanOffset = .zero }
                }
            }
            .padding(.vertical, 4)
        }
    }

    nonisolated private static func readTexturePixel(texture: MTLTexture, x: Int, y: Int, minValue: Float, maxValue: Float) -> Float? {
        guard x >= 0 && x < texture.width && y >= 0 && y < texture.height else { return nil }
        guard let device = MetalShared.device,
              let queue = MetalShared.queue else { return nil }

        let isRGBA = texture.pixelFormat == .rgba32Float || texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba8Unorm
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
        return minValue + ptr[0] * (maxValue - minValue)
    }
}
