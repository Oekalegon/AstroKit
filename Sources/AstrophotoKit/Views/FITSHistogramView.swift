import SwiftUI
import Charts
import Metal
import os

/// Data point for histogram chart
private struct HistogramDataPoint: Identifiable {
    let id: Int
    let intensity: Float
    let count: Float
}

/// SwiftUI view that displays a histogram of a FITS image using Swift Charts
@available(iOS 16.0, macOS 13.0, *)
public struct FITSHistogramView: View {
    let histogram: Histogram
    let showNormalized: Bool
    let blackPoint: Float?
    let whitePoint: Float?
    let showFullRange: Bool
    let useLogScale: Bool
    
    /// Initialize the histogram view
    /// - Parameters:
    ///   - histogram: The histogram data to display
    ///   - showNormalized: If true, shows normalized values (0-1), otherwise shows raw counts
    ///   - blackPoint: Optional black point for filtering (in original pixel value range)
    ///   - whitePoint: Optional white point for filtering (in original pixel value range)
    ///   - showFullRange: If true, shows full range; if false, shows only black/white point range
    ///   - useLogScale: If true, applies logarithmic transformation to Y-axis for better visualization of wide dynamic ranges
    public init(histogram: Histogram, showNormalized: Bool = true, blackPoint: Float? = nil, whitePoint: Float? = nil, showFullRange: Bool = true, useLogScale: Bool = false) {
        self.histogram = histogram
        self.showNormalized = showNormalized
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        self.showFullRange = showFullRange
        self.useLogScale = useLogScale
    }
    
    private var chartData: [HistogramDataPoint] {
        let range = histogram.maxValue - histogram.minValue
        
        // When histogram is computed for a specific range (black/white points),
        // all bins are already within that range, so we don't need to filter.
        // Just map all bins to their pixel values, including empty bins (count = 0).
        let data = histogram.binCounts.enumerated().map { index, count in
            // Map bin index to actual pixel value range
            // Bin 0 corresponds to minValue, bin (numBins-1) corresponds to maxValue
            let normalizedBinCenter = (Float(index) + 0.5) / Float(histogram.numBins)
            let actualPixelValue = histogram.minValue + normalizedBinCenter * range
            
            // Always include the bin, even if count is 0
            let rawValue = showNormalized ? histogram.normalizedBinCounts[index] : Float(count)
            
            // Apply logarithmic transformation if enabled
            let displayValue: Float
            if useLogScale && !showNormalized && rawValue > 0 {
                // Use log10(1 + value) for logarithmic scale
                displayValue = log10(1.0 + rawValue)
            } else {
                displayValue = rawValue
            }
            return HistogramDataPoint(id: index, intensity: actualPixelValue, count: displayValue)
        }
        
        // Debug: Print chart data statistics
        let nonZeroDataPoints = data.filter { $0.count > 0 }
        let maxCount = data.map { $0.count }.max() ?? 0
        Logger.ui.debug("Chart data: totalPoints=\(data.count), nonZeroPoints=\(nonZeroDataPoints.count), maxCount=\(maxCount), range=[\(histogram.minValue), \(histogram.maxValue)]")
        if nonZeroDataPoints.count < 10 {
            Logger.ui.debug("First few non-zero points:")
            for point in nonZeroDataPoints.prefix(5) {
                Logger.ui.debug("intensity=\(point.intensity), count=\(point.count)")
            }
        }
        
        return data
    }
    
    private var yAxisMax: Double {
        // Calculate max Y value for the axis
        if showNormalized {
            return 1.0 // Normalized values are always 0-1
        } else {
            let maxCount = Double(histogram.maxBinCount)
            if useLogScale && maxCount > 0 {
                // Use log10(1 + maxCount) with padding for logarithmic scale
                return log10(1.0 + maxCount * 1.1)
            } else {
                // Use the max bin count, but ensure at least 1 so empty histograms still show
                return max(maxCount * 1.1, 1.0) // Add 10% padding, minimum 1.0
            }
        }
    }
    
    private var xAxisRange: ClosedRange<Double> {
        if let bp = blackPoint, let wp = whitePoint, bp < wp {
            return Double(bp)...Double(wp)
        }
        return Double(histogram.minValue)...Double(histogram.maxValue)
    }
    
    public var body: some View {
        Chart(chartData) { dataPoint in
            LineMark(
                x: .value("Intensity", dataPoint.intensity),
                y: .value("Count", dataPoint.count)
            )
            .foregroundStyle(.blue)
            .lineStyle(StrokeStyle(lineWidth: 1.0))
            .interpolationMethod(.linear) // No smoothing, just connect points directly
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
            }
        }
        .chartXScale(domain: xAxisRange)
        .chartYScale(domain: 0...yAxisMax)
        .chartYAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
            }
        }
        .frame(height: 200)
    }
}

/// Task ID for histogram computation to avoid multiple recomputations
private struct TaskID: Equatable {
    let imageID: String?
    let imageWidth: Int
    let imageHeight: Int
    let textureMinValue: Float
    let textureMaxValue: Float
    let numBins: Int
    let blackPoint: Float?
    let whitePoint: Float?
}

/// SwiftUI view that computes and displays a histogram from a FITS image or texture
@available(iOS 16.0, macOS 13.0, *)
public struct FITSHistogramChart: View {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureMinValue: Float
    let textureMaxValue: Float
    let imageID: String?
    let numBins: Int?
    let showNormalized: Bool
    let blackPoint: Float?
    let whitePoint: Float?
    let showFullRange: Bool
    let useLogScale: Bool
    @State private var histogram: Histogram?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var currentTask: Task<Void, Never>?
    @State private var lastComputedImageID: String = ""
    
    /// Initialize with FITS image
    public init(fitsImage: FITSImage?, imageID: String? = nil, numBins: Int? = nil, showNormalized: Bool = false, blackPoint: Float? = nil, whitePoint: Float? = nil, showFullRange: Bool = true, useLogScale: Bool = false) {
        self.fitsImage = fitsImage
        self.texture = nil
        self.textureMinValue = 0.0
        self.textureMaxValue = 1.0
        self.imageID = imageID
        self.numBins = numBins
        self.showNormalized = showNormalized
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        self.showFullRange = showFullRange
        self.useLogScale = useLogScale
    }
    
    /// Initialize with texture
    public init(texture: MTLTexture?, textureMinValue: Float, textureMaxValue: Float, imageID: String? = nil, numBins: Int? = nil, showNormalized: Bool = false, blackPoint: Float? = nil, whitePoint: Float? = nil, showFullRange: Bool = true, useLogScale: Bool = false) {
        self.fitsImage = nil
        self.texture = texture
        self.textureMinValue = textureMinValue
        self.textureMaxValue = textureMaxValue
        self.imageID = imageID
        self.numBins = numBins
        self.showNormalized = showNormalized
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        self.showFullRange = showFullRange
        self.useLogScale = useLogScale
    }
    
    /// Calculate appropriate number of bins based on image data type
    private var calculatedNumBins: Int {
        if let numBins = numBins {
            return numBins
        }
        guard let fitsImage = fitsImage else {
            return 256
        }
        
        // Calculate bins based on data type and dynamic range
        switch fitsImage.dataType {
        case .byte:
            // 8-bit: 256 possible values
            return 256
        case .short:
            // 16-bit: 65536 possible values, use 512 bins for good resolution without crowding
            return 512
        case .long, .longLong:
            // 32/64-bit integer: use 512 bins
            return 512
        case .float, .double:
            // Floating point: use 512 bins (continuous values)
            return 512
        }
    }
    
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let histogram = histogram {
                FITSHistogramView(histogram: histogram, showNormalized: showNormalized, blackPoint: blackPoint, whitePoint: whitePoint, showFullRange: showFullRange, useLogScale: useLogScale)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 200)
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 200)
            } else {
                Text("No histogram data")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 200)
            }
        }
        .task(id: TaskID(
            imageID: imageID,
            imageWidth: fitsImage?.width ?? texture?.width ?? 0,
            imageHeight: fitsImage?.height ?? texture?.height ?? 0,
            textureMinValue: textureMinValue,
            textureMaxValue: textureMaxValue,
            numBins: calculatedNumBins,
            blackPoint: blackPoint,
            whitePoint: whitePoint
        )) {
            await computeHistogram()
        }
    }
    
    @MainActor
    private func computeHistogram() async {
        // Create a unique ID for the current image (without settings)
        let currentImageID: String
        if let fitsImage = fitsImage {
            currentImageID = "fits_\(fitsImage.width)x\(fitsImage.height)_\(fitsImage.originalMinValue)_\(fitsImage.originalMaxValue)"
        } else if let texture = texture {
            // Use texture dimensions and value range as ID
            currentImageID = "tex_\(texture.width)x\(texture.height)_\(textureMinValue)_\(textureMaxValue)"
        } else {
            // No image - clear histogram
            histogram = nil
            lastComputedImageID = ""
            return
        }
        
        // If image changed (not just settings), reset histogram state
        if currentImageID != lastComputedImageID {
            histogram = nil
            errorMessage = nil
            lastComputedImageID = currentImageID
        }
        
        // Always proceed with computation - the TaskID ensures we only recompute when needed
        // Cancel any previous computation
        currentTask?.cancel()
        
        // Determine which source we're using
        let sourceTexture: MTLTexture?
        let imageMinValue: Float
        let imageMaxValue: Float
        
        if let fitsImage = fitsImage {
            // Use FITS image
            guard let device = MTLCreateSystemDefaultDevice() else {
                histogram = nil
                errorMessage = "Metal not available"
                isLoading = false
                currentTask = nil
                return
            }
            do {
                sourceTexture = try fitsImage.createMetalTexture(device: device)
                imageMinValue = fitsImage.originalMinValue
                imageMaxValue = fitsImage.originalMaxValue
            } catch {
                histogram = nil
                errorMessage = "Failed to create texture: \(error.localizedDescription)"
                isLoading = false
                currentTask = nil
                return
            }
        } else if let texture = texture {
            // Use texture directly
            sourceTexture = texture
            imageMinValue = textureMinValue
            imageMaxValue = textureMaxValue
        } else {
            histogram = nil
            errorMessage = nil
            isLoading = false
            currentTask = nil
            return
        }
        
        guard let texture = sourceTexture else {
            histogram = nil
            errorMessage = "No texture available"
            isLoading = false
            currentTask = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        // Add a small delay to debounce rapid changes (e.g., when dragging sliders)
        try? await Task.sleep(nanoseconds: 150_000_000) // 0.15 second
        
        // Check if cancelled
        guard !Task.isCancelled else {
            isLoading = false
            currentTask = nil
            return
        }
        
        let binsToUse = calculatedNumBins
        
        // Determine the range for histogram computation
        // If showing clipped range, use black/white points; otherwise use full image range
        let histogramMin: Float
        let histogramMax: Float
        
        if let blackPoint = blackPoint, let whitePoint = whitePoint,
           whitePoint > blackPoint, (whitePoint - blackPoint) > 0.001 {
            // Always compute over the visible [blackPoint, whitePoint] range for maximum resolution.
            histogramMin = blackPoint
            histogramMax = whitePoint
        } else {
            histogramMin = imageMinValue
            histogramMax = imageMaxValue
        }
        
        // Ensure valid range
        guard histogramMax > histogramMin else {
            self.histogram = nil
            self.isLoading = false
            self.errorMessage = "Invalid histogram range"
            self.currentTask = nil
            return
        }
        
        // Debug: Print histogram computation parameters
        Logger.ui.debug("Computing histogram: showFullRange=\(showFullRange), histogramRange=[\(histogramMin), \(histogramMax)], imageRange=[\(imageMinValue), \(imageMaxValue)], bins=\(binsToUse)")
        if let blackPoint = blackPoint, let whitePoint = whitePoint {
            Logger.ui.debug("Black point: \(blackPoint), White point: \(whitePoint)")
        }
        
        // Compute histogram on a background thread using Metal for performance
        do {
            let computer = try HistogramComputer()
            let computedHistogram = try await Task.detached {
                // Use Metal-based histogram computation for performance
                // Pass full image range separately from histogram range
                return try computer.computeHistogram(
                    from: texture,
                    numBins: binsToUse,
                    minValue: histogramMin,
                    maxValue: histogramMax,
                    imageMinValue: imageMinValue,
                    imageMaxValue: imageMaxValue
                )
            }.value
            
            // Check if cancelled before updating
            guard !Task.isCancelled else {
                self.isLoading = false
                self.currentTask = nil
                return
            }
            
            // Debug: Print histogram statistics
            let nonZeroBins = computedHistogram.binCounts.filter { $0 > 0 }.count
            let totalPixels = computedHistogram.totalPixels
            let maxBinCount = computedHistogram.maxBinCount
            Logger.ui.debug("Histogram computed: range=[\(computedHistogram.minValue), \(computedHistogram.maxValue)], bins=\(computedHistogram.numBins), nonZeroBins=\(nonZeroBins), totalPixels=\(totalPixels), maxBinCount=\(maxBinCount)")
            if nonZeroBins < 10 {
                // Print first few non-zero bins
                for (index, count) in computedHistogram.binCounts.enumerated() where count > 0 {
                    let pixelValue = computedHistogram.minValue + (Float(index) + 0.5) / Float(computedHistogram.numBins) * (computedHistogram.maxValue - computedHistogram.minValue)
                    Logger.ui.debug("Bin \(index): count=\(count), pixelValue≈\(pixelValue)")
                }
            }
            
            self.histogram = computedHistogram
            self.isLoading = false
            self.errorMessage = nil
            self.currentTask = nil
        } catch {
            guard !Task.isCancelled else {
                self.isLoading = false
                self.currentTask = nil
                return
            }
            self.errorMessage = error.localizedDescription
            self.isLoading = false
            self.histogram = nil
            self.currentTask = nil
        }
    }
}

