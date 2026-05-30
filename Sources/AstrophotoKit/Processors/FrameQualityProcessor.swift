import Foundation
import Metal
import TabularData
import os

/// Aggregates star-detection and background-estimation results into a compact
/// per-frame quality summary for light frames.
///
/// This processor is intended as the final step of the `frame_quality` pipeline.
/// It consumes the outputs of earlier steps (FWHM-refined star catalogue,
/// background level table, and the original input frame for ADU conversion) and
/// produces a single-row `frame_quality` table that is automatically persisted to
/// the archive by the pipeline runner.
///
/// **Inputs**
/// - `input_frame`       (Frame)     — original light frame; used for ADU conversion
///                                     via `fitsMinValue` / `fitsMaxValue`.
/// - `pixel_coordinates` (TableData) — per-star table from `FWHMProcessor` containing
///                                     at minimum: fwhm_major, fwhm_minor, eccentricity,
///                                     saturated.
/// - `background_level`  (TableData) — single-row table from `BackgroundEstimationProcessor`
///                                     containing a `background_level` column (normalised 0–1).
///
/// **Outputs**
/// - `frame_quality` (TableData) — single-row summary table.
///
/// **Output columns**
/// | Column                            | Type   | Description                                                                   |
/// |-----------------------------------|--------|-------------------------------------------------------------------------------|
/// | star_count                        | Int    | Genuine point sources: saturated stars + unsaturated sources passing filters. |
/// | saturated_star_count              | Int    | Sources whose peak pixel ≥ 90 % of full-scale (saturated).                   |
/// | excluded_source_count             | Int    | Blobs rejected as non-stellar by max_fwhm_arcsec or max_eccentricity filter. |
/// | median_fwhm                       | Double | Median FWHM in pixels (avg major+minor), excluding outliers.                  |
/// | median_eccentricity               | Double | Median eccentricity 0–1 (0=circular), excluding outliers.                     |
/// | median_snr                        | Double | Median peak SNR of non-saturated, non-outlier stars (when background σ known).|
/// | low_snr_count                     | Int    | Number of stars with peak SNR below `low_snr_threshold` (default 5).         |
/// | background_level                  | Double | Normalised background level 0–1 (for backward compatibility).                 |
/// | background_level_adu              | Double | Background level in ADU (when FITS scale info available).                     |
/// | background_noise_sigma_adu        | Double | Per-pixel background noise sigma in ADU (NMAD of background-subtracted frame).|
/// | effective_detection_threshold_adu | Double | Effective detection floor = background_adu + threshold_sigma × noise_sigma_adu|
/// | threshold_sigma_used              | Double | Detection threshold sigma multiplier used (pipeline parameter, default 3.0).  |
/// | background_level_electrons        | Double | Background in electrons = (ADU−offset)×EGAIN (when EGAIN available).          |
/// | suggested_threshold_value         | Double | Recommended threshold sigma for re-running detection (needs `median_snr`).    |
/// | suggested_blur_radius             | Double | Recommended Gaussian blur radius for re-running detection (needs `median_fwhm`).|
/// | suggested_max_fwhm_arcsec         | Double | Recommended FWHM upper cutoff in arcseconds (needs `median_fwhm` + pixscale). |
public struct FrameQualityProcessor: Processor {

    public var id: String { "frame_quality" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Input frame (for ADU conversion)
        let (inputFrame, _) = try ProcessorHelpers.validateInputFrame(from: inputs)

        // Star table from FWHM processor
        guard let starTable = inputs["pixel_coordinates"] as? TableData,
              let starDF = starTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("pixel_coordinates")
        }

        // Background level and noise sigma from background estimation.
        // background_noise_sigma is NMAD of the background-subtracted frame (normalized 0–1).
        let bgRow: DataFrame.Row? = {
            guard let bgTable = inputs["background_level"] as? TableData,
                  let bgDF   = bgTable.dataFrame else { return nil }
            return bgDF.rows.first
        }()
        let backgroundLevelNorm: Double? = bgRow.flatMap { $0["background_level"] as? Double }
        let noiseSigmaNorm:      Double? = bgRow.flatMap { $0["background_noise_sigma"] as? Double }

        // Convert noise sigma to ADU: sigma is a spread so it scales by (fitsMax − fitsMin), no offset.
        let noiseSigmaADU: Double? = noiseSigmaNorm.flatMap { sigma in
            guard let fitsMin = inputFrame.fitsMinValue,
                  let fitsMax = inputFrame.fitsMaxValue else { return nil }
            return sigma * (fitsMax - fitsMin)
        }

        // Detection threshold sigma — mirrors what the threshold step used.
        let thresholdSigma: Double = parameters["threshold_sigma"]?.doubleValue ?? 3.0

        // Threshold below which a source is considered low-SNR.
        let lowSNRThreshold: Double = parameters["low_snr_threshold"]?.doubleValue ?? 5.0

        // Read FWHM upper cutoff (arcseconds → pixels using pixel scale when available).
        // Sources above the cutoff are extended objects (galaxy cores, nebulae) rather than
        // stars, so they would inflate the seeing metric if included.
        let maxFWHMPixels: Double? = {
            guard let arcsec = parameters["max_fwhm_arcsec"]?.doubleValue, arcsec > 0 else { return nil }
            if let scale = inputFrame.pixelScale, scale > 0 {
                return arcsec / scale
            }
            // No PIXSCALE in FITS header: apply the limit directly as pixels so the
            // filter remains active. The numeric value is the same; only the unit is wrong.
            Logger.processor.notice(
                "FrameQualityProcessor: max_fwhm_arcsec=\(arcsec) but frame has no PIXSCALE — applying as pixel limit"
            )
            return arcsec
        }()

        // Read eccentricity upper cutoff. Sources above this (cosmic rays, satellite trails)
        // are not point sources and should not contribute to the median eccentricity.
        let maxEccentricity: Double? = {
            guard let v = parameters["max_eccentricity"]?.doubleValue, v > 0 else { return nil }
            return v
        }()

        // Compute per-star quality metrics (FWHM, eccentricity, and SNR when noise sigma is known).
        let metrics = computeMetrics(
            from: starDF,
            maxFWHMPixels: maxFWHMPixels,
            maxEccentricity: maxEccentricity,
            noiseSigmaNorm: noiseSigmaNorm,
            lowSNRThreshold: lowSNRThreshold
        )

        // Convert background level to ADU using FITS scale info when available.
        let backgroundLevelADU: Double? = backgroundLevelNorm.flatMap { inputFrame.toADU($0) }

        // Convert to electrons when EGAIN is available — cross-camera comparable.
        // Formula: (adu - offset) × egain  (offset defaults to 0 when absent).
        let backgroundLevelElectrons: Double? = backgroundLevelNorm.flatMap { inputFrame.toElectrons($0) }

        // Effective detection threshold in ADU: the sky floor a real source must exceed.
        let effectiveThresholdADU: Double? = backgroundLevelADU.flatMap { bg in
            noiseSigmaADU.map { sigma in bg + thresholdSigma * sigma }
        }

        let bgInfo = backgroundLevelElectrons.map { String(format: ", bg=%.1f e⁻", $0) }
            ?? backgroundLevelADU.map { String(format: ", bg=%.1f ADU", $0) }
            ?? ""
        let fwhmStr  = String(format: "%.2f", metrics.medianFWHM ?? 0)
        let eccStr   = String(format: "%.3f", metrics.medianEccentricity ?? 0)
        let snrStr   = metrics.medianSNR.map { String(format: ", SNR=%.1f", $0) } ?? ""
        let noiseStr = noiseSigmaADU.map { String(format: ", σ=%.2f ADU", $0) } ?? ""
        Logger.processor.info(
            "FrameQualityProcessor: \(metrics.starCount) stars (\(metrics.saturatedStarCount) saturated), FWHM=\(fwhmStr)px, ecc=\(eccStr)\(snrStr)\(noiseStr)\(bgInfo)"
        )

        // Write output table
        guard var table = outputs["frame_quality"] as? TableData else { return }
        var df = DataFrame()
        df.append(column: Column(name: "star_count",           contents: [metrics.starCount]))
        df.append(column: Column(name: "saturated_star_count", contents: [metrics.saturatedStarCount]))
        df.append(column: Column(name: "excluded_source_count", contents: [metrics.excludedCount]))
        df.append(column: Column(name: "median_fwhm",          contents: [metrics.medianFWHM ?? 0.0]))
        df.append(column: Column(name: "median_eccentricity",  contents: [metrics.medianEccentricity ?? 0.0]))
        if let snr = metrics.medianSNR {
            df.append(column: Column(name: "median_snr",   contents: [snr]))
            df.append(column: Column(name: "low_snr_count", contents: [metrics.lowSNRCount]))
        }
        df.append(column: Column(name: "background_level",        contents: [backgroundLevelNorm ?? 0.0]))
        df.append(column: Column(name: "threshold_sigma_used",     contents: [thresholdSigma]))
        if let adu = backgroundLevelADU {
            df.append(column: Column(name: "background_level_adu", contents: [adu]))
        }
        if let sigma = noiseSigmaADU {
            df.append(column: Column(name: "background_noise_sigma_adu", contents: [sigma]))
        }
        if let threshold = effectiveThresholdADU {
            df.append(column: Column(name: "effective_detection_threshold_adu", contents: [threshold]))
        }
        if let electrons = backgroundLevelElectrons {
            df.append(column: Column(name: "background_level_electrons", contents: [electrons]))
        }

        // Parameter suggestions derived from computed quality metrics.
        // suggested_threshold_value: lower threshold = more stars when sources are bright.
        if let snr = metrics.medianSNR {
            let suggested = min(max(snr / 3.0, 1.5), 5.0)
            df.append(column: Column(name: "suggested_threshold_value", contents: [suggested]))
        }
        if let fwhm = metrics.medianFWHM {
            // suggested_blur_radius: smooth sub-PSF noise without smearing stars.
            let suggestedBlur = min(max(fwhm / 4.0, 1.0), 5.0)
            df.append(column: Column(name: "suggested_blur_radius", contents: [suggestedBlur]))
            // suggested_max_fwhm_arcsec: 3× typical seeing with a 4″ floor (requires pixel scale).
            if let scale = inputFrame.pixelScale, scale > 0 {
                let fwhmArcsec = fwhm * scale
                // Suggest 1.5× measured FWHM as headroom for seeing variation,
                // but never above the current max_fwhm_arcsec setting (default 8 arcsec).
                // Anything above 8 arcsec is already poor seeing — we don't suggest
                // loosening the filter past the user's own limit.
                let currentMax = parameters["max_fwhm_arcsec"]?.doubleValue ?? 8.0
                let suggestion = min(currentMax, max(4.0, 1.5 * fwhmArcsec))
                df.append(column: Column(name: "suggested_max_fwhm_arcsec", contents: [suggestion]))
            }
        }

        table.dataFrame = df
        outputs["frame_quality"] = table
    }

    // MARK: - Private

    private struct Metrics {
        let starCount: Int
        let saturatedStarCount: Int
        let excludedCount: Int
        let medianFWHM: Double?
        let medianEccentricity: Double?
        let medianSNR: Double?
        let lowSNRCount: Int
    }

    private func computeMetrics(
        from df: DataFrame,
        maxFWHMPixels: Double?,
        maxEccentricity: Double?,
        noiseSigmaNorm: Double?,
        lowSNRThreshold: Double
    ) -> Metrics {
        let fwhmMajorCol    = df.columns.first(where: { $0.name == "fwhm_major" })
        let fwhmMinorCol    = df.columns.first(where: { $0.name == "fwhm_minor" })
        let eccentricityCol = df.columns.first(where: { $0.name == "eccentricity" })
        let saturatedCol    = df.columns.first(where: { $0.name == "saturated" })
        let fluxCol         = df.columns.first(where: { $0.name == "flux" })

        var saturatedCount = 0
        var qualifyingCount = 0  // unsaturated point sources that passed the filters
        var fwhmValues: [Double] = []
        var eccValues:  [Double] = []
        var snrValues:  [Double] = []
        var excludedCount = 0

        for i in 0..<df.rows.count {
            let sat = (saturatedCol?[i] as? Bool) ?? false
            if sat {
                // Saturated sources are stars regardless of FWHM (bloom makes FWHM unreliable).
                saturatedCount += 1
                continue
            }

            let major = fwhmMajorCol?[i] as? Double
            let minor = fwhmMinorCol?[i] as? Double
            let ecc   = eccentricityCol?[i] as? Double
            let flux  = fluxCol?[i] as? Double

            let fwhm: Double? = (major.flatMap { m in minor.map { n in (m + n) / 2.0 } }).flatMap { $0 > 0 ? $0 : nil }
            let eccValid = ecc.flatMap { $0.isNaN ? nil : $0 }

            // Reject blobs that cannot be stars: galaxy cores, extended nebulae (too large),
            // cosmic rays, and satellite trails (too elongated).
            let exceedsFWHM = maxFWHMPixels.flatMap { cutoff in fwhm.map     { $0 > cutoff } } ?? false
            let exceedsEcc  = maxEccentricity.flatMap { maxEcc in eccValid.map { $0 > maxEcc } } ?? false
            if exceedsFWHM || exceedsEcc {
                excludedCount += 1
                continue
            }

            // This blob qualifies as a star.
            qualifyingCount += 1
            if let f = fwhm { fwhmValues.append(f) }
            if let e = eccValid { eccValues.append(e) }

            // Peak SNR estimate: flux / (noise × effective PSF area).
            // For a 2-D Gaussian PSF: effective_pixels = 2π × σ_x × σ_y, σ = FWHM/2.355.
            if let sigma = noiseSigmaNorm, sigma > 0,
               let fVal = flux, fVal > 0,
               let majorVal = major, majorVal > 0,
               let minorVal = minor, minorVal > 0 {
                let sigmaX = majorVal / 2.355
                let sigmaY = minorVal / 2.355
                let effPixels = 2.0 * .pi * sigmaX * sigmaY
                guard effPixels > 0 else { continue }
                snrValues.append(fVal / (sigma * sqrt(effPixels)))
            }
        }

        if excludedCount > 0 {
            Logger.processor.debug("FrameQualityProcessor: rejected \(excludedCount) non-stellar blob(s) (FWHM or eccentricity filter)")
        }

        let medSNR = snrValues.isEmpty ? nil : median(snrValues)
        let lowSNRCount = snrValues.filter { $0 < lowSNRThreshold }.count

        return Metrics(
            starCount: saturatedCount + qualifyingCount,
            saturatedStarCount: saturatedCount,
            excludedCount: excludedCount,
            medianFWHM: fwhmValues.isEmpty ? nil : median(fwhmValues),
            medianEccentricity: eccValues.isEmpty  ? nil : median(eccValues),
            medianSNR: medSNR,
            lowSNRCount: lowSNRCount
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 0
            ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
            : sorted[n / 2]
    }
}
