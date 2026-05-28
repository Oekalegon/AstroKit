import Foundation

/// Registry for processors
/// Implemented as an actor for thread-safe access in concurrent execution contexts
public actor ProcessorRegistry {
    private var implementations: [String: any Processor] = [:]
    private var isInitialized = false
    public static let shared = ProcessorRegistry()

    /// Create a new registry instance (useful for testing)
    public init() {}

    /// Automatically register all built-in processors
    /// This is called lazily when the registry is first accessed
    private func initializeIfNeeded() {
        guard !isInitialized else { return }
        isInitialized = true

        // Register all built-in processors
        registerBuiltInProcessors()
    }

    /// Register all built-in processors
    /// Only registers processors that haven't been manually registered yet
    private func registerBuiltInProcessors() {
        // Register built-in processors only if they're not already registered
        let grayscale = GrayscaleProcessor()
        if implementations[grayscale.id] == nil {
            register(grayscale)
        }

        let gaussianBlur = GaussianBlurProcessor()
        if implementations[gaussianBlur.id] == nil {
            register(gaussianBlur)
        }

        let backgroundEstimation = BackgroundEstimationProcessor()
        if implementations[backgroundEstimation.id] == nil {
            register(backgroundEstimation)
        }

        let threshold = ThresholdProcessor()
        if implementations[threshold.id] == nil {
            register(threshold)
        }

        let erosion = ErosionProcessor()
        if implementations[erosion.id] == nil {
            register(erosion)
        }

        let dilation = DilationProcessor()
        if implementations[dilation.id] == nil {
            register(dilation)
        }

        let connectedComponents = ConnectedComponentsProcessor()
        if implementations[connectedComponents.id] == nil {
            register(connectedComponents)
        }

        let quads = QuadsProcessor()
        if implementations[quads.id] == nil {
            register(quads)
        }

        let starDetectionOverlay = StarDetectionOverlayProcessor()
        if implementations[starDetectionOverlay.id] == nil {
            register(starDetectionOverlay)
        }

        let fwhm = FWHMProcessor()
        if implementations[fwhm.id] == nil {
            register(fwhm)
        }

        let opticalQuality = OpticalQualityProcessor()
        if implementations[opticalQuality.id] == nil {
            register(opticalQuality)
        }

        let houghCircles = HoughCircleProcessor()
        if implementations[houghCircles.id] == nil {
            register(houghCircles)
        }

        let collimationAnalysis = CollimationAnalysisProcessor()
        if implementations[collimationAnalysis.id] == nil {
            register(collimationAnalysis)
        }

        let hfd = HFDProcessor()
        if implementations[hfd.id] == nil {
            register(hfd)
        }

        let autofocusCurve = AutofocusCurveProcessor()
        if implementations[autofocusCurve.id] == nil {
            register(autofocusCurve)
        }

        let houghCircleOverlay = HoughCircleOverlayProcessor()
        if implementations[houghCircleOverlay.id] == nil {
            register(houghCircleOverlay)
        }

        let radialProfile = RadialProfileProcessor()
        if implementations[radialProfile.id] == nil {
            register(radialProfile)
        }

        let waveletDonut = WaveletDonutProcessor()
        if implementations[waveletDonut.id] == nil {
            register(waveletDonut)
        }

        let ringSearch = RingSearchProcessor()
        if implementations[ringSearch.id] == nil {
            register(ringSearch)
        }

        let frameRegistration = FrameRegistrationProcessor()
        if implementations[frameRegistration.id] == nil {
            register(frameRegistration)
        }

        let frameRegistrationTriangle = FrameRegistrationTriangleProcessor()
        if implementations[frameRegistrationTriangle.id] == nil {
            register(frameRegistrationTriangle)
        }

        let frameStacking = FrameStackingProcessor()
        if implementations[frameStacking.id] == nil {
            register(frameStacking)
        }

        let frameQuality = FrameQualityProcessor()
        if implementations[frameQuality.id] == nil {
            register(frameQuality)
        }

        let calibrationQuality = CalibrationQualityProcessor()
        if implementations[calibrationQuality.id] == nil {
            register(calibrationQuality)
        }
    }

    /// Register a processor using its `id` property
    /// The processor's `id` should match the `type` value in the pipeline step YAML
    /// - Parameter processor: The processor implementation
    public func register(_ processor: any Processor) {
        implementations[processor.id] = processor
    }

    /// Register a processor with an explicit type identifier
    /// - Parameters:
    ///   - type: The step type identifier (e.g., "gaussian_blur")
    ///   - implementation: The processor implementation
    public func register(type: String, implementation: any Processor) {
        implementations[type] = implementation
    }

    /// Get a processor by type
    /// Automatically initializes the registry with built-in processors on first access
    /// - Parameter type: The step type identifier
    /// - Returns: The processor, or nil if not found
    public func get(id: String) -> (any Processor)? {
        initializeIfNeeded()
        return implementations[id]
    }

    /// Get all registered processor IDs (sorted)
    public func getAllIDs() -> [String] {
        initializeIfNeeded()
        return Array(implementations.keys).sorted()
    }

    /// Clear all registered processors (useful for testing)
    public func clear() {
        implementations.removeAll()
    }
}
