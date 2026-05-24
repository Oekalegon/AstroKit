import SwiftUI
import Charts

/// Tab selection for the info panel
public enum FITSInfoPanelTab: String, CaseIterable {
    case information = "Information"
    case image = "Image"
    case pipeline = "Pipeline"
    
    public var systemImage: String {
        switch self {
        case .information: return "info.circle"
        case .image: return "chart.bar"
        case .pipeline: return "gearshape.2"
        }
    }
}

/// SwiftUI view for the FITS info panel with tabs
@available(iOS 16.0, macOS 13.0, *)
public struct FITSInfoPanelView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let frame: Frame?
    let table: TableData?
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
    
    public init(fitsImage: FITSImage? = nil, texture: MTLTexture? = nil, frame: Frame? = nil, table: TableData? = nil, textureWidth: Int = 0, textureHeight: Int = 0, textureMinValue: Float = 0.0, textureMaxValue: Float = 1.0, imageID: String? = nil, blackPoint: Binding<Float>, whitePoint: Binding<Float>, cursorPosition: SIMD2<Float>? = nil, aspectRatio: SIMD2<Float> = SIMD2<Float>(1.0, 1.0), extractedRegion: FITSImage? = nil, extractedRegionTexture: MTLTexture? = nil, extractedRegionSize: Binding<Int> = .constant(30), zoom: Binding<Float> = .constant(1.0), panOffset: Binding<SIMD2<Float>> = .constant(SIMD2<Float>(0, 0)), onExtractedRegionSizeChanged: ((Int) -> Void)? = nil) {
        self.fitsImage = fitsImage
        self.texture = texture
        self.frame = frame
        self.table = table
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
            // Tab selection
            Picker("Tab", selection: $selectedTab) {
                ForEach(FITSInfoPanelTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            // Tab content
            TabView(selection: $selectedTab) {
                InformationTabView(fitsImage: fitsImage, texture: texture, textureWidth: textureWidth, textureHeight: textureHeight)
                    .tag(FITSInfoPanelTab.information)
                
                ImageTabView(fitsImage: fitsImage, texture: texture, textureWidth: textureWidth, textureHeight: textureHeight, textureMinValue: textureMinValue, textureMaxValue: textureMaxValue, imageID: imageID, blackPoint: $blackPoint, whitePoint: $whitePoint, cursorPosition: cursorPosition, aspectRatio: aspectRatio, extractedRegion: extractedRegion, extractedRegionTexture: extractedRegionTexture, extractedRegionSize: $extractedRegionSize, zoom: $zoom, panOffset: $panOffset, onExtractedRegionSizeChanged: onExtractedRegionSizeChanged)
                    .tag(FITSInfoPanelTab.image)
                
                PipelineTabView(frame: frame, table: table)
                    .tag(FITSInfoPanelTab.pipeline)
            }
            .tabViewStyle(.automatic)
        }
        .frame(minWidth: 300, idealWidth: 350, maxWidth: 400)
    }
}

/// Pipeline tab showing processing history
@available(iOS 16.0, macOS 13.0, *)
private struct PipelineTabView: View {
    let frame: Frame?
    let table: TableData?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let frame = frame, let texture = frame.texture {
                    // Image properties
                    GroupBox("Image Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Width", value: "\(texture.width) px")
                            InfoRow(label: "Height", value: "\(texture.height) px")
                            InfoRow(label: "Color Space", value: "\(frame.colorSpace)")
                            InfoRow(label: "Data Type", value: frame.dataType?.description ?? "Unknown")
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let table = table, table.dataFrame != nil {
                    // Table properties
                    GroupBox("Table Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Rows", value: "\(table.rowCount)")
                            InfoRow(label: "Columns", value: "\(table.columnCount)")
                            InfoRow(label: "Column Names", value: table.columnNames.joined(separator: ", "))
                        }
                        .padding(.vertical, 4)
                    }
                }

                if frame == nil && table == nil {
                    Text("No pipeline data available")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .padding()
        }
    }
}


/// Information tab showing FITS metadata
@available(iOS 16.0, macOS 13.0, *)
private struct InformationTabView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureWidth: Int
    let textureHeight: Int
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let fitsImage = fitsImage {
                    // Basic image information
                    GroupBox("Image Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Width", value: "\(fitsImage.width) px")
                            InfoRow(label: "Height", value: "\(fitsImage.height) px")
                            if fitsImage.depth > 1 {
                                InfoRow(label: "Depth", value: "\(fitsImage.depth)")
                            }
                            InfoRow(label: "Total Pixels", value: "\(fitsImage.width * fitsImage.height)")
                            InfoRow(label: "Data Type", value: fitsImage.dataType.description)
                            if let bitpix = fitsImage.metadata["BITPIX"]?.intValue {
                                InfoRow(label: "BITPIX", value: "\(bitpix)")
                            }
                            InfoRow(label: "Min Value", value: String(format: "%.6f", fitsImage.originalMinValue))
                            InfoRow(label: "Max Value", value: String(format: "%.6f", fitsImage.originalMaxValue))
                        }
                        .padding(.vertical, 4)
                    }
                    
                    // FITS metadata
                    GroupBox("FITS Header") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(fitsImage.metadata.keys.sorted()), id: \.self) { key in
                                if let value = fitsImage.metadata[key] {
                                    InfoRow(label: key, value: formatHeaderValue(value))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Text("No FITS image loaded")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding()
        }
    }
    
    private func formatHeaderValue(_ value: FITSHeaderValue) -> String {
        switch value {
        case .string(let str): return str
        case .integer(let int): return "\(int)"
        case .floatingPoint(let double): return String(format: "%.6f", double)
        case .boolean(let bool): return bool ? "T" : "F"
        case .comment(let comment): return comment
        }
    }
}

/// Image tools tab with histogram
@available(iOS 16.0, macOS 13.0, *)
private struct ImageTabView: View {
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
    
    /// Read pixel value from a Metal texture
    /// - Parameters:
    ///   - texture: The Metal texture to read from
    ///   - x: X coordinate (0 to width-1)
    ///   - y: Y coordinate (0 to height-1)
    ///   - textureMinValue: Minimum value in the texture's original range
    ///   - textureMaxValue: Maximum value in the texture's original range
    /// - Returns: The pixel value in the original range, or nil if coordinates are out of bounds
    private func readTexturePixelValue(
        texture: MTLTexture,
        x: Int,
        y: Int,
        textureMinValue: Float,
        textureMaxValue: Float
    ) -> Float? {
        // Check bounds
        guard x >= 0 && x < texture.width && y >= 0 && y < texture.height else {
            return nil
        }
        
        // Read pixel value from texture
        // We'll read a small region (1x1 pixel) to get the exact value
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        // Metal requires bytesPerRow to be a multiple of 16 bytes
        // For a single pixel, we need at least 16 bytes
        let bytesPerPixel = MemoryLayout<Float32>.size
        let bytesPerRow = max(16, bytesPerPixel) // Must be at least 16 bytes
        let bufferSize = bytesPerRow // At least 16 bytes for alignment
        
        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            return nil
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        
        // Copy single pixel from texture
        // Note: For RGBA textures, we need to handle 4 channels, but for grayscale we only need R
        let pixelFormat = texture.pixelFormat
        let isRGBA = pixelFormat == .rgba32Float || pixelFormat == .rgba16Float || pixelFormat == .rgba8Unorm
        
        if isRGBA {
            // For RGBA, read all 4 channels (16 bytes total)
            let rgbaBytesPerRow = 16 // 4 floats * 4 bytes = 16 bytes (meets alignment requirement)
            let rgbaBufferSize = rgbaBytesPerRow
            
            guard let rgbaBuffer = device.makeBuffer(length: rgbaBufferSize, options: [.storageModeShared]) else {
                return nil
            }
            
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: rgbaBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: rgbaBytesPerRow,
                destinationBytesPerImage: rgbaBufferSize
            )
            blitEncoder.endEncoding()
            
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            if commandBuffer.error != nil {
                return nil
            }
            
            // Read RGBA values
            let rgbaPointer = rgbaBuffer.contents().bindMemory(to: Float32.self, capacity: 4)
            let normalizedValue = rgbaPointer[0] // Use red channel (or average for grayscale)
            
            // Convert to original value range
            let range = textureMaxValue - textureMinValue
            let originalValue = textureMinValue + normalizedValue * range
            
            return originalValue
        } else {
            // For grayscale textures (r32Float), use aligned buffer
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: readBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bufferSize
            )
            blitEncoder.endEncoding()
            
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            if commandBuffer.error != nil {
                return nil
            }
            
            // Read the pixel value (normalized 0-1)
            let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: 1)
            let normalizedValue = pixelPointer[0]
            
            // Convert to original value range
            let range = textureMaxValue - textureMinValue
            let originalValue = textureMinValue + normalizedValue * range
            
            return originalValue
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Always use texture for pixel information if available, fall back to FITSImage
                    if let cursorPos = cursorPosition {
                        GroupBox("Pixel Information") {
                            VStack(alignment: .leading, spacing: 8) {
                            // Use texture coordinates if texture is available
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
                                    
                                    // Read pixel value from texture
                                    if let intensity = readTexturePixelValue(
                                        texture: texture,
                                        x: pixelX,
                                        y: pixelY,
                                        textureMinValue: textureMinValue,
                                        textureMaxValue: textureMaxValue
                                    ) {
                                        InfoRow(label: "Intensity", value: String(format: "%.6f", intensity))
                                    } else {
                                        InfoRow(label: "Intensity", value: "N/A")
                                    }
                                } else {
                                    Text("Cursor outside image bounds")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else if let fitsImage = fitsImage {
                                // Fall back to FITSImage if no texture
                                if let pixelCoords = fitsImage.screenToImagePixel(
                                    normalizedX: cursorPos.x,
                                    normalizedY: cursorPos.y,
                                    zoom: zoom,
                                    panOffset: panOffset,
                                    aspectRatio: aspectRatio
                                ) {
                                    InfoRow(label: "X", value: "\(pixelCoords.x)")
                                    InfoRow(label: "Y", value: "\(pixelCoords.y)")
                                    
                                    if let intensity = fitsImage.getPixelValue(x: pixelCoords.x, y: pixelCoords.y) {
                                        InfoRow(label: "Intensity", value: String(format: "%.6f", intensity))
                                    } else {
                                        InfoRow(label: "Intensity", value: "N/A")
                                    }
                                } else {
                                    Text("Cursor outside image bounds")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                // Always use texture for histogram if available, fall back to FITSImage
                if texture != nil || fitsImage != nil {
                    GroupBox("Histogram") {
                        VStack(alignment: .leading, spacing: 8) {
                            // Toggle for full range vs clipped range
                            Toggle("Show Full Range", isOn: $showFullRange)
                                .font(.caption)
                            
                            // Toggle for log scale
                            Toggle("Use Log Scale", isOn: $useLogScale)
                                .font(.caption)
                            
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
                    
                    // Black/White point controls - use texture values if available, fall back to FITSImage
                    let minValue = texture != nil ? textureMinValue : (fitsImage?.originalMinValue ?? 0.0)
                    let maxValue = texture != nil ? textureMaxValue : (fitsImage?.originalMaxValue ?? 1.0)
                    
                    GroupBox("Image Adjustments") {
                        VStack(alignment: .leading, spacing: 12) {
                            // Black point slider
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Black Point")
                                        .font(.caption)
                                        .frame(width: 80, alignment: .leading)
                                    Text(String(format: "%.3f", blackPoint))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                Slider(value: $blackPoint, in: minValue...whitePoint) {
                                    Text("Black Point")
                                }
                            }
                            
                            // White point slider
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("White Point")
                                        .font(.caption)
                                        .frame(width: 80, alignment: .leading)
                                    Text(String(format: "%.3f", whitePoint))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                Slider(value: $whitePoint, in: blackPoint...maxValue) {
                                    Text("White Point")
                                }
                            }
                            
                            Button(action: {
                                blackPoint = minValue
                                whitePoint = maxValue
                            }) {
                                Text("Reset")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    // Extracted region view - prefer texture, fall back to FITSImage
                    if let extractedRegionTexture = extractedRegionTexture {
                        GroupBox("Extracted Region (\(extractedRegionSize)×\(extractedRegionSize))") {
                            VStack(alignment: .leading, spacing: 8) {
                                // Region size picker
                                HStack {
                                    Text("Size:")
                                        .font(.caption)
                                    Picker("Region Size", selection: $extractedRegionSize) {
                                        ForEach(regionSizes, id: \.self) { size in
                                            Text("\(size)×\(size)").tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .onChange(of: extractedRegionSize) { _, newSize in
                                        onExtractedRegionSizeChanged?(newSize)
                                    }
                                }
                                .padding(.horizontal, 4)
                                
                                FITSImageView(
                                    texture: extractedRegionTexture,
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
                                .onAppear {
                                    // Reset zoom and pan for extracted region to show full region
                                    extractedRegionZoom = 1.0
                                    extractedRegionPanOffset = SIMD2<Float>(0, 0)
                                }
                                .onChange(of: extractedRegionSize) { _, _ in
                                    // Reset zoom and pan when region size changes
                                    extractedRegionZoom = 1.0
                                    extractedRegionPanOffset = SIMD2<Float>(0, 0)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        // Cross-section graphs for texture
                        GroupBox("Cross Sections") {
                            FITSCrossSectionView(
                                texture: extractedRegionTexture,
                                textureMinValue: textureMinValue,
                                textureMaxValue: textureMaxValue
                            )
                            .frame(height: 200)
                        }
                    } else if let extractedRegion = extractedRegion {
                        GroupBox("Extracted Region (\(extractedRegionSize)×\(extractedRegionSize))") {
                            VStack(alignment: .leading, spacing: 8) {
                                // Region size picker
                                HStack {
                                    Text("Size:")
                                        .font(.caption)
                                    Picker("Region Size", selection: $extractedRegionSize) {
                                        ForEach(regionSizes, id: \.self) { size in
                                            Text("\(size)×\(size)").tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .onChange(of: extractedRegionSize) { _, newSize in
                                        onExtractedRegionSizeChanged?(newSize)
                                    }
                                }
                                .padding(.horizontal, 4)
                                
                                FITSImageView(
                                    fitsImage: extractedRegion,
                                    displayMode: .normal,
                                    zoom: $extractedRegionZoom,
                                    panOffset: $extractedRegionPanOffset,
                                    blackPoint: $blackPoint,
                                    whitePoint: $whitePoint,
                                    isInteractive: false
                                )
                                .frame(height: 200)
                                .onAppear {
                                    // Reset zoom and pan for extracted region to show full region
                                    extractedRegionZoom = 1.0
                                    extractedRegionPanOffset = SIMD2<Float>(0, 0)
                                }
                                .onChange(of: extractedRegion) { _, _ in
                                    // Reset zoom and pan when region changes
                                    extractedRegionZoom = 1.0
                                    extractedRegionPanOffset = SIMD2<Float>(0, 0)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        // Cross-section graphs for FITSImage
                        GroupBox("Cross Sections") {
                            FITSCrossSectionView(fitsImage: extractedRegion)
                                .frame(height: 200)
                        }
                    }
                }
                
                // Show "No image" message only if neither texture nor FITSImage is available
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
}

/// Cross-section data point for chart
private struct CrossSectionDataPoint: Identifiable {
    let id: Int
    let position: Float
    let intensity: Float
}

/// Cross-section data point with series identifier
private struct CrossSectionPoint: Identifiable {
    let id: UUID = UUID()
    let position: Float
    let intensity: Float
    let series: String
}

/// View displaying cross-sections along center X and Y axes
@available(iOS 16.0, macOS 13.0, *)
private struct FITSCrossSectionView: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureMinValue: Float
    let textureMaxValue: Float
    
    init(fitsImage: FITSImage? = nil, texture: MTLTexture? = nil, textureMinValue: Float = 0.0, textureMaxValue: Float = 1.0) {
        self.fitsImage = fitsImage
        self.texture = texture
        self.textureMinValue = textureMinValue
        self.textureMaxValue = textureMaxValue
    }
    
    private func getCenterXCrossSection() -> [Float] {
        if let fitsImage = fitsImage {
            return fitsImage.getCenterXCrossSection()
        } else if let texture = texture {
            return getTextureCenterXCrossSection(texture: texture)
        }
        return []
    }
    
    private func getCenterYCrossSection() -> [Float] {
        if let fitsImage = fitsImage {
            return fitsImage.getCenterYCrossSection()
        } else if let texture = texture {
            return getTextureCenterYCrossSection(texture: texture)
        }
        return []
    }
    
    private func getTextureCenterXCrossSection(texture: MTLTexture) -> [Float] {
        let width = texture.width
        let height = texture.height
        let centerY = height / 2
        
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return []
        }
        
        // Metal requires bytesPerRow to be a multiple of 16 bytes
        // For RGBA textures, each pixel is 16 bytes (4 floats * 4 bytes)
        // For grayscale textures, each pixel is 4 bytes
        let pixelFormat = texture.pixelFormat
        let isRGBA = pixelFormat == .rgba32Float || pixelFormat == .rgba16Float || pixelFormat == .rgba8Unorm
        let bytesPerPixel = isRGBA ? MemoryLayout<Float32>.size * 4 : MemoryLayout<Float32>.size
        let bytesPerRow = width * bytesPerPixel
        // Align to 16-byte boundary
        let alignedBytesPerRow = ((bytesPerRow + 15) / 16) * 16
        let bufferSize = alignedBytesPerRow
        
        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            return []
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return []
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return []
        }
        
        // Copy center row from texture
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: centerY, z: 0),
            sourceSize: MTLSize(width: width, height: 1, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: alignedBytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if commandBuffer.error != nil {
            return []
        }
        
        // Read pixel values and convert to original range
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: isRGBA ? width * 4 : width)
        var values: [Float] = []
        values.reserveCapacity(width)
        
        let range = textureMaxValue - textureMinValue
        
        for x in 0..<width {
            if isRGBA {
                // For RGBA, each pixel is 4 floats (R, G, B, A)
                // Pixel at x is at index x * 4 (red channel)
                let normalizedValue = pixelPointer[x * 4]
                let originalValue = textureMinValue + normalizedValue * range
                values.append(originalValue)
            } else {
                // For grayscale, each pixel is 1 float
                // For a single row, pixels are contiguous (alignment only affects multi-row buffers)
                let normalizedValue = pixelPointer[x]
                let originalValue = textureMinValue + normalizedValue * range
                values.append(originalValue)
            }
        }
        
        return values
    }
    
    private func getTextureCenterYCrossSection(texture: MTLTexture) -> [Float] {
        let width = texture.width
        let height = texture.height
        let centerX = width / 2
        
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return []
        }
        
        // Metal requires bytesPerRow to be a multiple of 16 bytes
        let pixelFormat = texture.pixelFormat
        let isRGBA = pixelFormat == .rgba32Float || pixelFormat == .rgba16Float || pixelFormat == .rgba8Unorm
        let bytesPerPixel = isRGBA ? MemoryLayout<Float32>.size * 4 : MemoryLayout<Float32>.size
        let bytesPerRow = width * bytesPerPixel
        // Align to 16-byte boundary
        let alignedBytesPerRow = ((bytesPerRow + 15) / 16) * 16
        let bufferSize = alignedBytesPerRow * height
        
        guard let readBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            return []
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return []
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return []
        }
        
        // Copy entire texture
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: alignedBytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if commandBuffer.error != nil {
            return []
        }
        
        // Read pixel values and extract center column
        let pixelPointer = readBuffer.contents().bindMemory(to: Float32.self, capacity: isRGBA ? width * height * 4 : width * height)
        var values: [Float] = []
        values.reserveCapacity(height)
        
        let range = textureMaxValue - textureMinValue
        
        for y in 0..<height {
            if isRGBA {
                // For RGBA, calculate index accounting for aligned row stride
                let rowOffset = y * (alignedBytesPerRow / MemoryLayout<Float32>.size)
                let pixelIndex = rowOffset + centerX * 4
                let normalizedValue = pixelPointer[pixelIndex] // Red channel
                let originalValue = textureMinValue + normalizedValue * range
                values.append(originalValue)
            } else {
                // For grayscale, calculate index accounting for aligned row stride
                let rowOffset = y * (alignedBytesPerRow / MemoryLayout<Float32>.size)
                let pixelIndex = rowOffset + centerX
                let normalizedValue = pixelPointer[pixelIndex]
                let originalValue = textureMinValue + normalizedValue * range
                values.append(originalValue)
            }
        }
        
        return values
    }
    
    var body: some View {
        if fitsImage != nil || texture != nil {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    // X-axis cross-section (horizontal line through center)
                    ForEach(Array(getCenterXCrossSection().enumerated()), id: \.offset) { index, intensity in
                        LineMark(
                            x: .value("Position", Float(index)),
                            y: .value("Intensity", intensity)
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(by: .value("Series", "X-axis"))
                    
                    // Y-axis cross-section (vertical line through center)
                    ForEach(Array(getCenterYCrossSection().enumerated()), id: \.offset) { index, intensity in
                        LineMark(
                            x: .value("Position", Float(index)),
                            y: .value("Intensity", intensity)
                        )
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(by: .value("Series", "Y-axis"))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisGridLine()
                        AxisTick()
                        if let doubleValue = value.as(Double.self) {
                            AxisValueLabel(String(format: "%.0f", doubleValue))
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .chartXAxisLabel("Pixel Position")
                .chartYAxisLabel("Intensity")
                .chartLegend {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 8, height: 8)
                            Text("X-axis")
                                .font(.caption)
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("Y-axis")
                                .font(.caption)
                        }
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
}

/// Helper view for displaying key-value pairs
private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

