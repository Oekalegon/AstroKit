import Foundation
import Metal
import TabularData
import os

/// Processor that analyses the spatial variation of star shapes across the image to
/// diagnose common optical problems: sensor tilt, coma, and backfocus errors.
///
/// The image is divided into a configurable grid (default 5×4). For each cell the
/// processor computes mean eccentricity, circular mean of position angle (orientation
/// is periodic over π, so it uses the 2θ mapping), and mean FWHM.  Summary diagnostics
/// compare these per-cell statistics to characteristic spatial patterns:
///
/// - Sensor tilt:  uniform eccentricity across the whole field with a consistent
///                 elongation direction (stars elongated the same way everywhere).
/// - Coma:         eccentricity increases with distance from centre; the elongation
///                 direction points toward/away from the optical axis.
/// - Backfocus:    the major/minor FWHM ratio increases radially from centre.
///
/// **Inputs**
/// - `input_frame`       (Frame) — used only to read image width and height.
/// - `pixel_coordinates` (TableData) — per-star table from FWHMProcessor, containing at
///   minimum: centroid_x, centroid_y, eccentricity, rotation_angle, fwhm_major,
///   fwhm_minor, saturated.
///
/// **Parameters**
/// - `grid_cols`          Int (default 5)  — number of grid columns.
/// - `grid_rows`          Int (default 4)  — number of grid rows.
/// - `min_stars_per_cell` Int (default 3)  — cells with fewer stars are excluded from
///                                           summary statistics.
///
/// **Outputs**
/// - `optical_quality_map`     (TableData) — one row per grid cell.
/// - `optical_quality_summary` (TableData) — one summary row with diagnosis.
public struct OpticalQualityProcessor: Processor {

    public var id: String { "optical_quality" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Read image dimensions from the input frame texture
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)
        let imageWidth  = Double(inputTexture.width)
        let imageHeight = Double(inputTexture.height)

        // Validate star table
        guard let starTable = inputs["pixel_coordinates"] as? TableData,
              let df = starTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("pixel_coordinates")
        }

        let gridCols         = parameters["grid_cols"]?.intValue          ?? 5
        let gridRows         = parameters["grid_rows"]?.intValue          ?? 4
        let minStarsPerCell  = parameters["min_stars_per_cell"]?.intValue ?? 3

        Logger.processor.debug(
            "OpticalQualityProcessor: \(df.rows.count) stars, grid \(gridCols)×\(gridRows)"
        )

        // Extract star data
        let stars = try extractStars(from: df)

        // Assign each star to a grid cell
        let assigned = assignToGrid(
            stars: stars,
            gridCols: gridCols,
            gridRows: gridRows,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        // Compute per-cell statistics
        let cellStats = computeCellStats(
            assigned: assigned,
            gridCols: gridCols,
            gridRows: gridRows,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            minStarsPerCell: minStarsPerCell
        )

        // Compute summary diagnostics
        let summary = computeSummary(cellStats: cellStats)

        Logger.processor.info("OpticalQualityProcessor: diagnosis = \(summary.diagnosis)")

        try writeMapTable(outputs: &outputs, cellStats: cellStats)
        try writeSummaryTable(outputs: &outputs, summary: summary)
    }

    // MARK: - Data Extraction

    private struct StarData {
        let centroidX: Double
        let centroidY: Double
        let eccentricity: Double
        let rotationAngle: Double  // radians (orientation, periodic over π)
        let fwhmMajor: Double
        let fwhmMinor: Double
        let saturated: Bool
    }

    private func extractStars(from df: DataFrame) throws -> [StarData] {
        guard let cxCol    = df.columns.first(where: { $0.name == "centroid_x" }),
              let cyCol    = df.columns.first(where: { $0.name == "centroid_y" }),
              let eccCol   = df.columns.first(where: { $0.name == "eccentricity" }),
              let rotCol   = df.columns.first(where: { $0.name == "rotation_angle" }),
              let majCol   = df.columns.first(where: { $0.name == "fwhm_major" }),
              let minCol   = df.columns.first(where: { $0.name == "fwhm_minor" }) else {
            throw ProcessorExecutionError.executionFailed(
                "pixel_coordinates table missing required columns " +
                "(centroid_x, centroid_y, eccentricity, rotation_angle, fwhm_major, fwhm_minor)"
            )
        }

        let satCol = df.columns.first(where: { $0.name == "saturated" })

        return (0..<df.rows.count).compactMap { i in
            guard let cx  = cxCol[i]  as? Double,
                  let cy  = cyCol[i]  as? Double,
                  let ecc = eccCol[i] as? Double,
                  let rot = rotCol[i] as? Double,
                  let maj = majCol[i] as? Double,
                  let min = minCol[i] as? Double else { return nil }
            let sat = (satCol?[i] as? Bool) ?? false
            return StarData(
                centroidX: cx, centroidY: cy,
                eccentricity: ecc, rotationAngle: rot,
                fwhmMajor: maj, fwhmMinor: min,
                saturated: sat
            )
        }
    }

    // MARK: - Grid Assignment

    private struct AssignedStar {
        let cellID: Int
        let star: StarData
    }

    private func assignToGrid(
        stars: [StarData],
        gridCols: Int,
        gridRows: Int,
        imageWidth: Double,
        imageHeight: Double
    ) -> [AssignedStar] {
        stars.map { star in
            let col = min(gridCols - 1, max(0, Int(star.centroidX / imageWidth  * Double(gridCols))))
            let row = min(gridRows - 1, max(0, Int(star.centroidY / imageHeight * Double(gridRows))))
            return AssignedStar(cellID: row * gridCols + col, star: star)
        }
    }

    // MARK: - Per-Cell Statistics

    private struct CellStats {
        let cellID: Int
        let gridCol: Int
        let gridRow: Int
        let cellCenterX: Double
        let cellCenterY: Double
        let starCount: Int
        let meanEccentricity: Double
        let stddevEccentricity: Double
        let meanPositionAngle: Double    // radians
        let positionAngleRadial: Double  // alignment with radial direction
        let meanFWHMMajor: Double
        let meanFWHMMinor: Double
        let distFromCenterNorm: Double
    }

    private func computeCellStats(
        assigned: [AssignedStar],
        gridCols: Int,
        gridRows: Int,
        imageWidth: Double,
        imageHeight: Double,
        minStarsPerCell: Int
    ) -> [CellStats] {
        let halfDiag = sqrt(imageWidth * imageWidth + imageHeight * imageHeight) / 2.0

        // Group by cellID
        var groups: [Int: [StarData]] = [:]
        for a in assigned {
            groups[a.cellID, default: []].append(a.star)
        }

        var result: [CellStats] = []

        for cellID in 0..<(gridCols * gridRows) {
            let col = cellID % gridCols
            let row = cellID / gridCols

            let cellCX = (Double(col) + 0.5) / Double(gridCols) * imageWidth
            let cellCY = (Double(row) + 0.5) / Double(gridRows) * imageHeight

            let dx = cellCX - imageWidth  / 2.0
            let dy = cellCY - imageHeight / 2.0
            let distNorm = sqrt(dx * dx + dy * dy) / halfDiag
            let radialAngle = atan2(dy, dx)   // direction from image centre to cell centre

            let valid = (groups[cellID] ?? []).filter { !$0.saturated && $0.fwhmMajor > 0 }
            guard valid.count >= minStarsPerCell else {
                result.append(CellStats(
                    cellID: cellID, gridCol: col, gridRow: row,
                    cellCenterX: cellCX, cellCenterY: cellCY,
                    starCount: 0,
                    meanEccentricity: 0, stddevEccentricity: 0,
                    meanPositionAngle: 0, positionAngleRadial: 0,
                    meanFWHMMajor: 0, meanFWHMMinor: 0,
                    distFromCenterNorm: distNorm
                ))
                continue
            }

            let n = Double(valid.count)

            // Mean eccentricity
            let meanEcc = valid.map(\.eccentricity).reduce(0, +) / n
            let varEcc = valid.map { ($0.eccentricity - meanEcc) * ($0.eccentricity - meanEcc) }.reduce(0, +) / n
            let stdEcc = sqrt(max(0, varEcc))

            // Circular mean of position angle (orientation, periodic over π):
            // Map θ → 2θ, compute circular mean, then halve.
            let sinSum = valid.map { sin(2.0 * $0.rotationAngle) }.reduce(0, +)
            let cosSum = valid.map { cos(2.0 * $0.rotationAngle) }.reduce(0, +)
            let meanAngle = atan2(sinSum / n, cosSum / n) / 2.0

            // Difference between mean star elongation direction and radial direction
            let posAngleRadial = angleDifference(meanAngle, radialAngle)

            let meanMajor = valid.map(\.fwhmMajor).reduce(0, +) / n
            let meanMinor = valid.map(\.fwhmMinor).reduce(0, +) / n

            result.append(CellStats(
                cellID: cellID, gridCol: col, gridRow: row,
                cellCenterX: cellCX, cellCenterY: cellCY,
                starCount: valid.count,
                meanEccentricity: meanEcc, stddevEccentricity: stdEcc,
                meanPositionAngle: meanAngle, positionAngleRadial: posAngleRadial,
                meanFWHMMajor: meanMajor, meanFWHMMinor: meanMinor,
                distFromCenterNorm: distNorm
            ))
        }

        return result
    }

    /// Returns the smallest signed angular difference a - b, in [-π/2, π/2].
    private func angleDifference(_ a: Double, _ b: Double) -> Double {
        var diff = a - b
        while diff >  .pi / 2 { diff -= .pi }
        while diff < -.pi / 2 { diff += .pi }
        return diff
    }

    // MARK: - Summary Diagnostics

    private struct SummaryStats {
        let globalMeanEccentricity: Double
        let eccentricityUniformity: Double
        let comaScore: Double
        let tiltScore: Double
        let backfocusScore: Double
        let diagnosis: String
    }

    private func computeSummary(cellStats: [CellStats]) -> SummaryStats {
        let valid = cellStats.filter { $0.starCount > 0 }
        guard valid.count >= 3 else {
            return SummaryStats(
                globalMeanEccentricity: 0, eccentricityUniformity: 0,
                comaScore: 0, tiltScore: 0, backfocusScore: 0,
                diagnosis: "insufficient_data"
            )
        }

        let n = Double(valid.count)
        let eccValues  = valid.map(\.meanEccentricity)
        let distValues = valid.map(\.distFromCenterNorm)
        let fwhmRatioValues = valid.map { c in
            c.meanFWHMMinor > 0 ? c.meanFWHMMajor / c.meanFWHMMinor : 1.0
        }

        let globalMeanEcc = eccValues.reduce(0, +) / n
        let varEcc = eccValues.map { ($0 - globalMeanEcc) * ($0 - globalMeanEcc) }.reduce(0, +) / n
        let stdEcc = sqrt(max(0, varEcc))
        // Uniformity: 1 when all cells have identical eccentricity, 0 when highly variable.
        // Normalise by the mean so the score is scale-independent.
        let eccentricityUniformity = globalMeanEcc > 0.01
            ? max(0.0, 1.0 - stdEcc / globalMeanEcc)
            : 1.0

        // Coma: Pearson correlation of eccentricity vs. distance from centre
        let comaScore = pearsonR(eccValues, distValues)

        // Tilt: uniform eccentricity (high uniformity) with consistent position angle
        let paRadValues = valid.map { abs($0.positionAngleRadial) }
        let meanPaRad = paRadValues.reduce(0, +) / n
        // Low mean |positionAngleRadial| + high uniformity → coma-like (not tilt)
        // High uniformity + any direction → tilt
        let tiltScore = eccentricityUniformity

        // Backfocus: major/minor ratio increases radially from centre
        let backfocusScore = pearsonR(fwhmRatioValues, distValues)

        // Thresholds for diagnosis
        let diagnosis: String
        if globalMeanEcc < 0.15 {
            diagnosis = "well_collimated"
        } else if comaScore > 0.65 && meanPaRad < .pi / 6 {
            diagnosis = "coma"
        } else if backfocusScore > 0.65 {
            diagnosis = "backfocus"
        } else if tiltScore > 0.75 && globalMeanEcc > 0.2 {
            diagnosis = "sensor_tilt"
        } else {
            diagnosis = "well_collimated"
        }

        return SummaryStats(
            globalMeanEccentricity: globalMeanEcc,
            eccentricityUniformity: eccentricityUniformity,
            comaScore: comaScore,
            tiltScore: tiltScore,
            backfocusScore: backfocusScore,
            diagnosis: diagnosis
        )
    }

    /// Pearson correlation coefficient between two equal-length arrays.
    private func pearsonR(_ xs: [Double], _ ys: [Double]) -> Double {
        guard xs.count == ys.count, xs.count > 1 else { return 0 }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let dx  = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let dy  = ys.map { ($0 - my) * ($0 - my) }.reduce(0, +)
        let denom = sqrt(dx * dy)
        return denom > 0 ? num / denom : 0
    }

    // MARK: - Output Writing

    private func writeMapTable(
        outputs: inout [String: ProcessData],
        cellStats: [CellStats]
    ) throws {
        guard var table = outputs["optical_quality_map"] as? TableData else { return }

        var df = DataFrame()
        df.append(column: Column(name: "cell_id",               contents: cellStats.map(\.cellID)))
        df.append(column: Column(name: "grid_col",              contents: cellStats.map(\.gridCol)))
        df.append(column: Column(name: "grid_row",              contents: cellStats.map(\.gridRow)))
        df.append(column: Column(name: "cell_center_x",         contents: cellStats.map(\.cellCenterX)))
        df.append(column: Column(name: "cell_center_y",         contents: cellStats.map(\.cellCenterY)))
        df.append(column: Column(name: "star_count",            contents: cellStats.map(\.starCount)))
        df.append(column: Column(name: "mean_eccentricity",     contents: cellStats.map(\.meanEccentricity)))
        df.append(column: Column(name: "stddev_eccentricity",   contents: cellStats.map(\.stddevEccentricity)))
        df.append(column: Column(name: "mean_position_angle",   contents: cellStats.map(\.meanPositionAngle)))
        df.append(column: Column(name: "position_angle_radial", contents: cellStats.map(\.positionAngleRadial)))
        df.append(column: Column(name: "mean_fwhm_major",       contents: cellStats.map(\.meanFWHMMajor)))
        df.append(column: Column(name: "mean_fwhm_minor",       contents: cellStats.map(\.meanFWHMMinor)))
        df.append(column: Column(name: "dist_from_center_norm", contents: cellStats.map(\.distFromCenterNorm)))

        table.dataFrame = df
        outputs["optical_quality_map"] = table
    }

    private func writeSummaryTable(
        outputs: inout [String: ProcessData],
        summary: SummaryStats
    ) throws {
        guard var table = outputs["optical_quality_summary"] as? TableData else { return }

        var df = DataFrame()
        df.append(column: Column(name: "global_mean_eccentricity", contents: [summary.globalMeanEccentricity]))
        df.append(column: Column(name: "eccentricity_uniformity",  contents: [summary.eccentricityUniformity]))
        df.append(column: Column(name: "coma_score",               contents: [summary.comaScore]))
        df.append(column: Column(name: "tilt_score",               contents: [summary.tiltScore]))
        df.append(column: Column(name: "backfocus_score",          contents: [summary.backfocusScore]))
        df.append(column: Column(name: "diagnosis",                contents: [summary.diagnosis]))

        table.dataFrame = df
        outputs["optical_quality_summary"] = table
    }
}
