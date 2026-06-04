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

    private let regionSizes = [10, 20, 30, 40, 50]

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
                if let cursorPos = cursorPosition {
                    GroupBox("Pixel Information") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let texture = texture {
                                let texCoord = FITSCoordinateConverter.screenToTextureCoord(
                                    normalizedX: cursorPos.x,
                                    normalizedY: cursorPos.y,
                                    zoom: zoom,
                                    panOffset: panOffset,
                                    aspectRatio: aspectRatio
                                )
                                if let coord = texCoord {
                                    let pixelX = Int(coord.x * Float(textureWidth))
                                    let pixelY = Int(coord.y * Float(textureHeight))
                                    InfoRow(label: "X", value: "\(pixelX)")
                                    InfoRow(label: "Y", value: "\(pixelY)")
                                    if let intensity = readTexturePixel(texture: texture, x: pixelX, y: pixelY) {
                                        InfoRow(label: "Intensity", value: String(format: "%.6f", intensity))
                                    } else {
                                        InfoRow(label: "Intensity", value: "N/A")
                                    }
                                } else {
                                    Text("Cursor outside image bounds").font(.caption).foregroundColor(.secondary)
                                }
                            } else if let fitsImage = fitsImage {
                                if let px = fitsImage.screenToImagePixel(normalizedX: cursorPos.x, normalizedY: cursorPos.y, zoom: zoom, panOffset: panOffset, aspectRatio: aspectRatio) {
                                    InfoRow(label: "X", value: "\(px.x)")
                                    InfoRow(label: "Y", value: "\(px.y)")
                                    if let intensity = fitsImage.getPixelValue(x: px.x, y: px.y) {
                                        InfoRow(label: "Intensity", value: String(format: "%.6f", intensity))
                                    } else {
                                        InfoRow(label: "Intensity", value: "N/A")
                                    }
                                } else {
                                    Text("Cursor outside image bounds").font(.caption).foregroundColor(.secondary)
                                }
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

    private func readTexturePixel(texture: MTLTexture, x: Int, y: Int) -> Float? {
        guard x >= 0 && x < texture.width && y >= 0 && y < texture.height else { return nil }
        guard let device = MetalShared.device,
              let queue = MetalShared.queue else { return nil }

        let isRGBA = texture.pixelFormat == .rgba32Float || texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba8Unorm
        let bufSize = isRGBA ? 16 : max(16, MemoryLayout<Float32>.size)
        let bpr     = bufSize

        guard let buf  = device.makeBuffer(length: bufSize, options: .storageModeShared),
              let cmd  = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bufSize)
        blit.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        guard cmd.error == nil else { return nil }

        let ptr = buf.contents().bindMemory(to: Float32.self, capacity: isRGBA ? 4 : 1)
        let normalized = ptr[0]
        return textureMinValue + normalized * (textureMaxValue - textureMinValue)
    }
}
