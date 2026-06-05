/// Display stretch settings for a single frame.
///
/// Values are stored in normalized [0, 1] space relative to the frame's
/// [originalMinValue, originalMaxValue] range, making them independent of
/// bit depth, sensor gain, or BZERO/BSCALE scaling.
///
/// ## Composition model
///
/// The UI maintains two levels of stretch:
/// 1. A **saved stretch** (`StretchSettings`) that is persisted to the archive.
///    It records which sub-range of the image's full tonal range fills the display.
/// 2. A **slider position** (the live `blackPoint`/`whitePoint` bindings) that
///    allows fine-tuning on top of the saved stretch.
///
/// The effective (shader-ready) normalized values are computed by composing both:
/// ```
/// effectiveNorm = inputBlack + sliderNorm × (inputWhite − inputBlack)
/// ```
/// where `sliderNorm = (slider − originalMin) / (originalMax − originalMin)`.
///
/// ## Normalize workflow
///
/// When the user presses **Normalize**:
/// 1. The current effective black/white points are baked into a new `StretchSettings`
///    via `normalized(sliderBlackNorm:sliderWhiteNorm:)`.
/// 2. The live sliders reset to the full range (`originalMin … originalMax`),
///    giving the user the full slider travel for fine adjustment within the saved stretch.
/// 3. The display is unchanged — effective values before and after are identical.
///
/// ## Future extension (ASTR-47 — per-channel curves)
///
/// ```swift
/// // public var luminanceCurve: ToneCurve? = nil
/// // public var redCurve:       ToneCurve? = nil
/// // public var greenCurve:     ToneCurve? = nil
/// // public var blueCurve:      ToneCurve? = nil
/// ```
/// Curves will sit on top of the linear stretch and be applied after composition.
public struct StretchSettings: Codable, Hashable, Sendable {
    /// Normalized [0, 1] input value that maps to display black (0).
    public var inputBlack: Float
    /// Normalized [0, 1] input value that maps to display white (1).
    public var inputWhite: Float

    public init(inputBlack: Float = 0.0, inputWhite: Float = 1.0) {
        self.inputBlack = inputBlack
        self.inputWhite = inputWhite
    }

    /// Identity stretch — full image range maps to full display range.
    public static let identity = StretchSettings()

    /// `true` when this stretch is equivalent to showing the full image range.
    public var isIdentity: Bool { inputBlack == 0.0 && inputWhite == 1.0 }

    // MARK: - Composition

    /// Effective normalized value after composing the saved stretch with a slider position.
    ///
    /// - Parameter sliderNorm: Slider value normalized to [0, 1].
    ///   Compute as `(slider − originalMin) / (originalMax − originalMin)`.
    public func effective(sliderNorm: Float) -> Float {
        inputBlack + sliderNorm * (inputWhite - inputBlack)
    }

    // MARK: - Normalize

    /// Returns a new `StretchSettings` that bakes in the current slider positions,
    /// resetting the effective range to the full [0, 1] space.
    ///
    /// The display appearance is exactly preserved:
    /// `new.effective(sliderNorm: 0) == self.effective(sliderNorm: sliderBlackNorm)`
    /// `new.effective(sliderNorm: 1) == self.effective(sliderNorm: sliderWhiteNorm)`
    ///
    /// - Parameters:
    ///   - sliderBlackNorm: Current black slider normalized to [0, 1].
    ///   - sliderWhiteNorm: Current white slider normalized to [0, 1].
    public func normalized(sliderBlackNorm: Float, sliderWhiteNorm: Float) -> StretchSettings {
        StretchSettings(
            inputBlack: effective(sliderNorm: sliderBlackNorm),
            inputWhite: effective(sliderNorm: sliderWhiteNorm)
        )
    }
}
