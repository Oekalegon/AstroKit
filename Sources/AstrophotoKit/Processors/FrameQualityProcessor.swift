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
/// | Column                 | Type   | Description                                                 |
/// |------------------------|--------|-------------------------------------------------------------|
/// | star_count             | Int    | Total detected stars (including saturated).                 |
/// | saturated_star_count   | Int    | Stars whose peak pixel ≥ 90 % of full-scale (saturated).   |
/// | median_fwhm            | Double | Median FWHM in pixels (avg major+minor), unsaturated stars. |
/// | median_eccentricity    | Double | Median eccentricity 0–1 (0=circular), unsaturated stars.    |
/// | background_level       | Double | Normalised background level 0–1 (for backward compatibility). |
/// | background_level_adu       | Double | Background level in ADU (when FITS scale info available).      |
/// | background_level_electrons | Double | Background in electrons = (ADU−offset)×EGAIN (when EGAIN       |
/// |                            |        | is available). Cross-camera comparable.                        |
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

        // Background level from background estimation (optional — some custom pipelines may omit it)
        let backgroundLevelNorm: Double? = {
            guard let bgTable = inputs["background_level"] as? TableData,
                  let bgDF   = bgTable.dataFrame,
                  let row    = bgDF.rows.first,
                  let level  = row["background_level"] as? Double else { return nil }
            return level
        }()

        // Read FWHM upper cutoff (arcseconds → pixels using pixel scale when available).
        // Sources above the cutoff are extended objects (galaxy cores, nebulae) rather than
        // stars, so they would inflate the seeing metric if included.
        let maxFWHMPixels: Double? = {
            guard let arcsec = parameters["max_fwhm_arcsec"]?.doubleValue, arcsec > 0 else { return nil }
            guard let scale  = inputFrame.pixelScale, scale > 0 else {
                Logger.processor.debug("FrameQualityProcessor: max_fwhm_arcsec set but frame has no pixel scale — FWHM cutoff inactive")
                return nil
            }
            return arcsec / scale
        }()

        // Read eccentricity upper cutoff. Sources above this (cosmic rays, satellite trails)
        // are not point sources and should not contribute to the median eccentricity.
        let maxEccentricity: Double? = {
            guard let v = parameters["max_eccentricity"]?.doubleValue, v > 0 else { return nil }
            return v
        }()

        // Compute per-star quality metrics
        let metrics = computeMetrics(from: starDF, maxFWHMPixels: maxFWHMPixels, maxEccentricity: maxEccentricity)

        // Convert background level to ADU using FITS scale info when available.
        let backgroundLevelADU: Double? = backgroundLevelNorm.flatMap { inputFrame.toADU($0) }

        // Convert to electrons when EGAIN is available — cross-camera comparable.
        // Formula: (adu - offset) × egain  (offset defaults to 0 when absent).
        let backgroundLevelElectrons: Double? = backgroundLevelNorm.flatMap { inputFrame.toElectrons($0) }

        let bgInfo = backgroundLevelElectrons.map { String(format: ", bg=%.1f e⁻", $0) }
            ?? backgroundLevelADU.map { String(format: ", bg=%.1f ADU", $0) }
            ?? ""
        let fwhmStr = String(format: "%.2f", metrics.medianFWHM ?? 0)
        let eccStr  = String(format: "%.3f", metrics.medianEccentricity ?? 0)
        Logger.processor.info(
            "FrameQualityProcessor: \(metrics.starCount) stars (\(metrics.saturatedStarCount) saturated), FWHM=\(fwhmStr)px, ecc=\(eccStr)\(bgInfo)"
        )

        // Write output table
        guard var table = outputs["frame_quality"] as? TableData else { return }
        var df = DataFrame()
        df.append(column: Column(name: "star_count",           contents: [metrics.starCount]))
        df.append(column: Column(name: "saturated_star_count", contents: [metrics.saturatedStarCount]))
        df.append(column: Column(name: "median_fwhm",          contents: [metrics.medianFWHM ?? 0.0]))
        df.append(column: Column(name: "median_eccentricity",  contents: [metrics.medianEccentricity ?? 0.0]))
        df.append(column: Column(name: "background_level",     contents: [backgroundLevelNorm ?? 0.0]))
        if let adu = backgroundLevelADU {
            df.append(column: Column(name: "background_level_adu", contents: [adu]))
        }
        if let electrons = backgroundLevelElectrons {
            df.append(column: Column(name: "background_level_electrons", contents: [electrons]))
        }
        table.dataFrame = df
        outputs["frame_quality"] = table
    }

    // MARK: - Private

    private struct Metrics {
        let starCount: Int
        let saturatedStarCount: Int
        let medianFWHM: Double?
        let medianEccentricity: Double?
    }

    private func computeMetrics(from df: DataFrame, maxFWHMPixels: Double?, maxEccentricity: Double?) -> Metrics {
        let fwhmMajorCol    = df.columns.first(where: { $0.name == "fwhm_major" })
        let fwhmMinorCol    = df.columns.first(where: { $0.name == "fwhm_minor" })
        let eccentricityCol = df.columns.first(where: { $0.name == "eccentricity" })
        let saturatedCol    = df.columns.first(where: { $0.name == "saturated" })

        var saturatedCount = 0
        var fwhmValues: [Double] = []
        var eccValues:  [Double] = []
        var excludedCount = 0

        for i in 0..<df.rows.count {
            let sat = (saturatedCol?[i] as? Bool) ?? false
            if sat { saturatedCount += 1 }

            // Only unsaturated stars contribute to FWHM and eccentricity statistics.
            if !sat {
                let major = fwhmMajorCol?[i] as? Double
                let minor = fwhmMinorCol?[i] as? Double
                let ecc   = eccentricityCol?[i] as? Double

                let fwhm: Double? = (major.flatMap { m in minor.map { n in (m + n) / 2.0 } }).flatMap { $0 > 0 ? $0 : nil }
                let eccValid = ecc.flatMap { $0.isNaN ? nil : $0 }

                // Exclude extended objects (galaxy cores, nebulae) and non-stellar artifacts
                // (cosmic rays, satellite trails) from the statistics. These inflate seeing
                // and eccentricity medians because blob detection treats them like stars.
                let exceedsFWHM = maxFWHMPixels.flatMap { cutoff in fwhm.map     { $0 > cutoff } } ?? false
                let exceedsEcc  = maxEccentricity.flatMap { maxEcc in eccValid.map { $0 > maxEcc } } ?? false
                if exceedsFWHM || exceedsEcc {
                    excludedCount += 1
                    continue
                }

                if let f = fwhm { fwhmValues.append(f) }
                if let e = eccValid { eccValues.append(e) }
            }
        }

        if excludedCount > 0 {
            Logger.processor.debug("FrameQualityProcessor: excluded \(excludedCount) non-stellar source(s) from quality statistics")
        }

        return Metrics(
            starCount: df.rows.count,
            saturatedStarCount: saturatedCount,
            medianFWHM: fwhmValues.isEmpty ? nil : median(fwhmValues),
            medianEccentricity: eccValues.isEmpty  ? nil : median(eccValues)
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
