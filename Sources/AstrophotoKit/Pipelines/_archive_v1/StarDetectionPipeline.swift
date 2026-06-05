import Foundation
import Metal

/// Pipeline for star detection in astronomical images
/// 
/// This pipeline performs the following steps:
/// 1. Gaussian Blur - Reduces noise and smooths the image
/// 2. Background Estimation - Estimates and extracts the background
/// 3. Threshold - Creates a binary mask of potential stars
/// 
/// Future steps could include:
/// - Morphological operations (erosion, dilation)
/// - Connected component analysis
/// - Star catalog generation
public class StarDetectionPipeline: BasePipeline {

    /// Initialize the star detection pipeline
    /// - Parameters:
    ///   - blurRadius: Radius for Gaussian blur step (default: 3.0)
    ///   - thresholdValue: Threshold value for star detection (default: 3.0 for sigma method)
    ///   - thresholdMethod: Method for threshold calculation (default: .sigma)
    ///   - erosionKernelSize: Kernel size for erosion step (default: 3)
    ///   - dilationKernelSize: Kernel size for dilation step (default: 3)
    public init(
        blurRadius: Float = 3.0,
        thresholdValue: Float = 3.0,
        thresholdMethod: ThresholdStep.ThresholdMethod = .sigma,
        erosionKernelSize: Int = 3,
        dilationKernelSize: Int = 3
    ) {
        // Create pipeline steps
        let blurStep = GaussianBlurStep(defaultRadius: blurRadius)
        let backgroundStep = BackgroundEstimationStep()
        let thresholdStep = ThresholdStep(defaultThreshold: thresholdValue, defaultMethod: thresholdMethod)
        let erosionStep = ErosionStep(defaultKernelSize: erosionKernelSize)
        let dilationStep = DilationStep(defaultKernelSize: dilationKernelSize)
        let connectedComponentsStep = ConnectedComponentsStep()
        let quadsStep = QuadsStep()
        let starDetectionOverlayStep = StarDetectionOverlayStep()

        // Define the pipeline
        super.init(
            id: "star_detection",
            name: "Star Detection",
            description: "Detects stars in astronomical images using Gaussian blur, " +
                "background estimation, thresholding, erosion, dilation, " +
                "connected components analysis, quads, and draws ellipses around detected stars",
            steps: [
                blurStep, backgroundStep, thresholdStep, erosionStep, dilationStep,
                connectedComponentsStep, quadsStep, starDetectionOverlayStep
            ],
            requiredInputs: ["input_image"],
            optionalInputs: [
                "blur_radius", "threshold_value", "erosion_kernel_size",
                "dilation_kernel_size", "max_stars", "min_distance_percent", "k_neighbors",
                "ellipse_color_r", "ellipse_color_g", "ellipse_color_b", "ellipse_width",
                "quad_color_r", "quad_color_g", "quad_color_b", "quad_width"
            ],
            outputs: [
                "blurred_image",
                "background_image",
                "background_subtracted_image",
                "background_level",
                "thresholded_image",
                "eroded_image",
                "dilated_image",
                "pixel_coordinates",
                "coordinate_count",
                "quads",
                "annotated_image"
            ]
        )
    }

    /// Convenience initializer with default parameters
    public convenience init() {
        self.init(
            blurRadius: 3.0,
            thresholdValue: 3.0,
            thresholdMethod: .sigma,
            erosionKernelSize: 3,
            dilationKernelSize: 3
        )
    }
}

