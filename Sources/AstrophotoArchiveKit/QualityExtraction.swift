import AstrophotoKit
import Foundation

/// Extracts quality metrics from pipeline output `TableData` tables.
///
/// Shared between the `ap` CLI (`Run.swift`) and the `astrokit-mcp` MCP server
/// (`Tools.swift`) so the table-signature recognition logic lives in exactly one place.
public enum PipelineQualityExtractor {

    /// Result of extracting per-frame quality from a registration table.
    public typealias PerFrameQuality = (
        filePath: String,
        starCount: Int?,
        medianFWHM: Double?,
        medianEccentricity: Double?
    )

    /// Result of extracting aggregate quality metrics from single-frame pipeline output tables.
    public typealias GlobalQuality = (
        starCount: Int?,
        medianFWHM: Double?,
        backgroundNoise: Double?,
        backgroundNoiseIsADU: Bool,
        backgroundNoiseElectrons: Double?,
        medianEccentricity: Double?,
        saturatedStarCount: Int?,
        hotPixelCount: Int?,
        sunAltitude: Double?,
        moonSeparation: Double?,
        moonIllumination: Double?
    )

    // MARK: - Per-frame extraction

    /// Extracts per-frame quality metrics from a registration table.
    ///
    /// Identified by having `file_path`, `median_fwhm`, and `star_count` columns (produced by
    /// `FrameRegistrationProcessor` inside frame_registration_quad and frame_stacking pipelines).
    /// `sky_noise` (per-frame registration ADU value) is not mapped to `backgroundNoise` here;
    /// the stacking summary handles it separately.
    public static func extractPerFrameQuality(from tables: [TableData]) -> [PerFrameQuality] {
        for table in tables {
            guard let df = table.dataFrame else { continue }
            let colNames = Set(df.columns.map { $0.name })
            guard colNames.contains("file_path"),
                  colNames.contains("median_fwhm"),
                  colNames.contains("star_count") else { continue }

            var results: [PerFrameQuality] = []
            for row in df.rows {
                guard let path = row["file_path"] as? String, !path.isEmpty else { continue }
                let starCount: Int? = (row["star_count"] as? Int32).map { Int($0) }
                    ?? (row["star_count"] as? Int)
                let medianFWHM         = row["median_fwhm"] as? Double
                let medianEccentricity = row["mean_eccentricity"] as? Double
                results.append((filePath: path, starCount: starCount, medianFWHM: medianFWHM, medianEccentricity: medianEccentricity))
            }
            return results
        }
        return []
    }

    // MARK: - Global extraction

    /// Extracts aggregate quality metrics from single-frame analysis pipeline output tables.
    ///
    /// Recognised table signatures:
    /// - `frame_quality` (has `star_count`, `saturated_star_count`): compact summary from FrameQualityProcessor.
    /// - `calibration_quality` (has `noise_sigma`, `hot_pixel_count`): from CalibrationQualityProcessor.
    /// - `pixel_coordinates` (has `centroid_x`/`centroid_y`): legacy — row count → `starCount`.
    /// - `median_fwhm` summary (has `sigma_clipped_mean_fwhm_major/minor`): legacy → `medianFWHM`.
    /// - `background_level` table: prefers `background_level_adu` (ADU) over `background_level` (normalised).
    /// - `celestial_context` table (has `sun_altitude_deg`, `moon_separation_deg`, `moon_illumination`):
    ///   from CelestialContextProcessor.
    ///
    /// Returns `backgroundNoiseIsADU = true` when the background value was read from an ADU column.
    public static func extractGlobalQuality(from tables: [TableData]) -> GlobalQuality {
        var starCount: Int? = nil
        var medianFWHM: Double? = nil
        var backgroundNoise: Double? = nil
        var backgroundNoiseIsADU = false
        var backgroundNoiseElectrons: Double? = nil
        var medianEccentricity: Double? = nil
        var saturatedStarCount: Int? = nil
        var hotPixelCount: Int? = nil
        var sunAltitude: Double? = nil
        var moonSeparation: Double? = nil
        var moonIllumination: Double? = nil

        for table in tables {
            guard let df = table.dataFrame else { continue }
            let colNames = Set(df.columns.map { $0.name })

            // frame_quality table — compact summary from FrameQualityProcessor.
            if colNames.contains("star_count") && colNames.contains("saturated_star_count"),
               let row = df.rows.first {
                if let v = row["star_count"]           as? Int  { starCount = v }
                if let v = row["saturated_star_count"] as? Int  { saturatedStarCount = v }
                if let v = row["median_fwhm"]          as? Double, v > 0 { medianFWHM = v }
                if let v = row["median_eccentricity"]  as? Double { medianEccentricity = v }
                // Prefer ADU background over normalised; guard column existence first
                // because TabularData Row.subscript traps on missing columns.
                if colNames.contains("background_level_adu"),
                   let v = row["background_level_adu"] as? Double {
                    backgroundNoise = v; backgroundNoiseIsADU = true
                } else if let v = row["background_level"] as? Double {
                    backgroundNoise = v
                }
                if colNames.contains("background_level_electrons"),
                   let v = row["background_level_electrons"] as? Double {
                    backgroundNoiseElectrons = v
                }
            }

            // calibration_quality table — from CalibrationQualityProcessor.
            if colNames.contains("noise_sigma") && colNames.contains("hot_pixel_count"),
               let row = df.rows.first {
                if let v = row["hot_pixel_count"] as? Int { hotPixelCount = v }
                if colNames.contains("noise_sigma_adu"),
                   let v = row["noise_sigma_adu"] as? Double {
                    backgroundNoise = v; backgroundNoiseIsADU = true
                } else if let v = row["noise_sigma"] as? Double {
                    backgroundNoise = v
                }
                if colNames.contains("noise_sigma_electrons"),
                   let v = row["noise_sigma_electrons"] as? Double {
                    backgroundNoiseElectrons = v
                }
            }

            // Legacy: per-star table (star_detection / optical_quality).
            if colNames.contains("centroid_x") && colNames.contains("centroid_y") {
                if starCount == nil { starCount = df.rows.count }
                if medianEccentricity == nil {
                    let eccs = df.rows.compactMap { $0["eccentricity"] as? Double }.filter { !$0.isNaN }
                    if !eccs.isEmpty { medianEccentricity = eccs.reduce(0, +) / Double(eccs.count) }
                }
            }
            // Legacy: FWHM summary table (star_detection).
            if colNames.contains("sigma_clipped_mean_fwhm_major"),
               colNames.contains("sigma_clipped_mean_fwhm_minor"),
               let row = df.rows.first,
               let major = row["sigma_clipped_mean_fwhm_major"] as? Double,
               let minor = row["sigma_clipped_mean_fwhm_minor"] as? Double,
               major > 0, medianFWHM == nil {
                medianFWHM = (major + minor) / 2.0
            }
            // Legacy: background level table (background_estimation).
            // Prefer ADU column when present (BackgroundEstimationProcessor emits
            // background_level_adu whenever the frame has FITS scale info).
            if colNames.contains("background_level"),
               !colNames.contains("star_count"),   // avoid double-counting frame_quality table
               let row = df.rows.first,
               backgroundNoise == nil {
                if colNames.contains("background_level_adu"),
                   let v = row["background_level_adu"] as? Double {
                    backgroundNoise = v; backgroundNoiseIsADU = true
                } else if let v = row["background_level"] as? Double {
                    backgroundNoise = v
                }
            }
            // Legacy: optical_quality summary eccentricity.
            if colNames.contains("global_mean_eccentricity"),
               let row = df.rows.first,
               let ecc = row["global_mean_eccentricity"] as? Double,
               medianEccentricity == nil {
                medianEccentricity = ecc
            }
            // Celestial context table — from CelestialContextProcessor.
            if colNames.contains("sun_altitude_deg") || colNames.contains("moon_separation_deg") || colNames.contains("moon_illumination"),
               let row = df.rows.first {
                if sunAltitude == nil,     colNames.contains("sun_altitude_deg")    { sunAltitude     = row["sun_altitude_deg"]    as? Double }
                if moonSeparation == nil,  colNames.contains("moon_separation_deg") { moonSeparation  = row["moon_separation_deg"] as? Double }
                if moonIllumination == nil, colNames.contains("moon_illumination")  { moonIllumination = row["moon_illumination"]   as? Double }
            }
        }
        return (starCount, medianFWHM, backgroundNoise, backgroundNoiseIsADU, backgroundNoiseElectrons,
                medianEccentricity, saturatedStarCount, hotPixelCount, sunAltitude, moonSeparation, moonIllumination)
    }
}
