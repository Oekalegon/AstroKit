import SwiftUI

/// Tab selection for the info panel.
public enum FITSInfoPanelTab: String, CaseIterable {
    case information = "Information"
    case image = "Image"
    case pipeline = "Pipeline"

    public var systemImage: String {
        switch self {
        case .information: return "info.circle"
        case .image:       return "chart.bar"
        case .pipeline:    return "gearshape.2"
        }
    }
}

/// Convenience view that presents FITSInformationView, FITSImageToolsView, and FITSPipelineView
/// in a segmented tab layout. Use the individual views directly when you need a different presentation.
@available(iOS 16.0, macOS 13.0, *)
public struct FITSInfoPanelView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let processedImage: ProcessedImage?
    let processedTable: ProcessedTable?
    let processedScalar: ProcessedScalar?
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
    @State private var selectedTab: FITSInfoPanelTab = .information

    public init(
        fitsImage: FITSImage? = nil,
        texture: MTLTexture? = nil,
        processedImage: ProcessedImage? = nil,
        processedTable: ProcessedTable? = nil,
        processedScalar: ProcessedScalar? = nil,
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
        self.processedImage = processedImage
        self.processedTable = processedTable
        self.processedScalar = processedScalar
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
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(FITSInfoPanelTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            TabView(selection: $selectedTab) {
                FITSInformationView(fitsImage: fitsImage)
                    .tag(FITSInfoPanelTab.information)

                FITSImageToolsView(
                    fitsImage: fitsImage,
                    texture: texture,
                    textureWidth: textureWidth,
                    textureHeight: textureHeight,
                    textureMinValue: textureMinValue,
                    textureMaxValue: textureMaxValue,
                    imageID: imageID,
                    blackPoint: $blackPoint,
                    whitePoint: $whitePoint,
                    cursorPosition: cursorPosition,
                    aspectRatio: aspectRatio,
                    extractedRegion: extractedRegion,
                    extractedRegionTexture: extractedRegionTexture,
                    extractedRegionSize: $extractedRegionSize,
                    zoom: $zoom,
                    panOffset: $panOffset,
                    onExtractedRegionSizeChanged: onExtractedRegionSizeChanged
                )
                .tag(FITSInfoPanelTab.image)

                FITSPipelineView(processedImage: processedImage, processedTable: processedTable, processedScalar: processedScalar)
                    .tag(FITSInfoPanelTab.pipeline)
            }
            .tabViewStyle(.automatic)
        }
        .frame(minWidth: 300, idealWidth: 350, maxWidth: 400)
    }
}
