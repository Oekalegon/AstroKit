import Foundation
import Metal
import TabularData
import os

/// Processor that analyses the spatial distribution of donut offsets (inner vs. outer
/// circle centres) detected by `HoughCircleProcessor` to characterise the collimation
/// error of a reflector telescope.
///
/// For a well-collimated reflector the inner circle (secondary mirror shadow) should be
/// centred inside the outer circle (defocused star disc) at every position in the field.
/// A collimation error shifts the secondary relative to the primary, producing a
/// consistent offset direction and magnitude across the image.
///
/// The global mean offset vector `(collimation_offset_x, collimation_offset_y)` directly
/// encodes the direction and magnitude of the needed correction.
///
/// **Inputs**
/// - `donuts`      (TableData) — output from `HoughCircleProcessor`.
/// - `input_frame` (Frame)     — used only to read image dimensions for cell centres.
///
/// **Parameters**
/// - `grid_cols` Int (default 3)
/// - `grid_rows` Int (default 3)
///
/// **Outputs**
/// - `collimation_map`     (TableData) — per-cell statistics.
/// - `collimation_summary` (TableData) — one summary row with diagnosis.
public struct CollimationAnalysisProcessor: Processor {

    public var id: String { "collimation_analysis" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)
        let imageWidth  = Double(inputTexture.width)
        let imageHeight = Double(inputTexture.height)

        guard let donutTable = inputs["donuts"] as? TableData,
              let df = donutTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("donuts")
        }

        let gridCols = parameters["grid_cols"]?.intValue ?? 3
        let gridRows = parameters["grid_rows"]?.intValue ?? 3

        Logger.processor.debug(
            "CollimationAnalysisProcessor: \(df.rows.count) donuts, grid \(gridCols)×\(gridRows)"
        )

        // Extract per-donut offset data
        let donuts = try extractDonuts(from: df)

        // Assign to grid cells
        let cellStats = computeCellStats(
            donuts: donuts,
            gridCols: gridCols,
            gridRows: gridRows,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        // Compute global summary
        let summary = computeSummary(donuts: donuts, cellStats: cellStats)

        let collimLogMsg = String(
            format: "CollimationAnalysisProcessor: offset (%.2f, %.2f) px, diagnosis = %@",
            summary.offsetX, summary.offsetY, summary.diagnosis
        )
        Logger.processor.info("\(collimLogMsg)")

        try writeMapTable(outputs: &outputs, cellStats: cellStats)
        try writeSummaryTable(outputs: &outputs, summary: summary)
    }

    // MARK: - Data Extraction

    private struct DonutData {
        let outerCX: Double
        let outerCY: Double
        let offsetX: Double  // inner_cx - outer_cx
        let offsetY: Double  // inner_cy - outer_cy
        let offsetMagnitude: Double
        let offsetAngle: Double
    }

    private func extractDonuts(from df: DataFrame) throws -> [DonutData] {
        guard let ocxCol  = df["outer_cx"]         as? AnyColumn,
              let ocyCol  = df["outer_cy"]         as? AnyColumn,
              let offXCol = df["offset_x"]         as? AnyColumn,
              let offYCol = df["offset_y"]         as? AnyColumn,
              let offMCol = df["offset_magnitude"] as? AnyColumn,
              let offACol = df["offset_angle"]     as? AnyColumn else {
            throw ProcessorExecutionError.executionFailed(
                "donuts table missing required offset columns"
            )
        }

        return (0..<df.rows.count).compactMap { i in
            guard let cx = ocxCol[i]  as? Double,
                  let cy = ocyCol[i]  as? Double,
                  let ox = offXCol[i] as? Double,
                  let oy = offYCol[i] as? Double,
                  let om = offMCol[i] as? Double,
                  let oa = offACol[i] as? Double else { return nil }
            return DonutData(
                outerCX: cx, outerCY: cy,
                offsetX: ox, offsetY: oy,
                offsetMagnitude: om, offsetAngle: oa
            )
        }
    }

    // MARK: - Cell Statistics

    private struct CellStats {
        let cellID: Int
        let gridCol: Int
        let gridRow: Int
        let cellCenterX: Double
        let cellCenterY: Double
        let donutCount: Int
        let meanOffsetX: Double
        let meanOffsetY: Double
        let meanOffsetMagnitude: Double
        let meanOffsetAngle: Double
    }

    private func computeCellStats(
        donuts: [DonutData],
        gridCols: Int,
        gridRows: Int,
        imageWidth: Double,
        imageHeight: Double
    ) -> [CellStats] {
        // Group donuts by cell
        var groups: [Int: [DonutData]] = [:]
        for donut in donuts {
            let col = min(gridCols - 1, max(0, Int(donut.outerCX / imageWidth  * Double(gridCols))))
            let row = min(gridRows - 1, max(0, Int(donut.outerCY / imageHeight * Double(gridRows))))
            let cellID = row * gridCols + col
            groups[cellID, default: []].append(donut)
        }

        return (0..<(gridCols * gridRows)).map { cellID in
            let col = cellID % gridCols
            let row = cellID / gridCols
            let cellCX = (Double(col) + 0.5) / Double(gridCols) * imageWidth
            let cellCY = (Double(row) + 0.5) / Double(gridRows) * imageHeight

            let group = groups[cellID] ?? []
            guard !group.isEmpty else {
                return CellStats(
                    cellID: cellID, gridCol: col, gridRow: row,
                    cellCenterX: cellCX, cellCenterY: cellCY,
                    donutCount: 0,
                    meanOffsetX: 0, meanOffsetY: 0,
                    meanOffsetMagnitude: 0, meanOffsetAngle: 0
                )
            }

            let n = Double(group.count)
            let mox  = group.map(\.offsetX).reduce(0, +) / n
            let moy  = group.map(\.offsetY).reduce(0, +) / n
            let mom  = group.map(\.offsetMagnitude).reduce(0, +) / n
            let moa  = atan2(group.map { sin($0.offsetAngle) }.reduce(0, +) / n,
                             group.map { cos($0.offsetAngle) }.reduce(0, +) / n)

            return CellStats(
                cellID: cellID, gridCol: col, gridRow: row,
                cellCenterX: cellCX, cellCenterY: cellCY,
                donutCount: group.count,
                meanOffsetX: mox, meanOffsetY: moy,
                meanOffsetMagnitude: mom, meanOffsetAngle: moa
            )
        }
    }

    // MARK: - Summary Diagnostics

    private struct SummaryStats {
        let totalDonuts: Int
        let offsetX: Double
        let offsetY: Double
        let offsetMagnitude: Double
        let offsetAngle: Double
        let offsetUniformity: Double
        let diagnosis: String
    }

    private func computeSummary(
        donuts: [DonutData],
        cellStats: [CellStats]
    ) -> SummaryStats {
        guard !donuts.isEmpty else {
            return SummaryStats(
                totalDonuts: 0, offsetX: 0, offsetY: 0,
                offsetMagnitude: 0, offsetAngle: 0,
                offsetUniformity: 0, diagnosis: "insufficient_data"
            )
        }

        let n = Double(donuts.count)
        let globalOffX = donuts.map(\.offsetX).reduce(0, +) / n
        let globalOffY = donuts.map(\.offsetY).reduce(0, +) / n
        let globalMag  = sqrt(globalOffX * globalOffX + globalOffY * globalOffY)
        let globalAng  = atan2(globalOffY, globalOffX)

        // Offset uniformity: how consistent are individual offsets?
        // Measured as 1 - normalised circular stddev of offset angles.
        let sinMean = donuts.map { sin($0.offsetAngle) }.reduce(0, +) / n
        let cosMean = donuts.map { cos($0.offsetAngle) }.reduce(0, +) / n
        let R = sqrt(sinMean * sinMean + cosMean * cosMean)  // mean resultant length [0..1]
        let uniformity = R  // 1 = all angles identical, 0 = random scatter

        // Diagnosis thresholds (in pixels)
        let diagnosis: String
        if donuts.count < 3 {
            diagnosis = "insufficient_data"
        } else if globalMag < 2.0 && uniformity > 0.7 {
            diagnosis = "well_collimated"
        } else if globalMag < 5.0 {
            diagnosis = "needs_adjustment"
        } else {
            diagnosis = "severe_miscollimation"
        }

        return SummaryStats(
            totalDonuts: donuts.count,
            offsetX: globalOffX, offsetY: globalOffY,
            offsetMagnitude: globalMag, offsetAngle: globalAng,
            offsetUniformity: uniformity, diagnosis: diagnosis
        )
    }

    // MARK: - Output Writing

    private func writeMapTable(
        outputs: inout [String: ProcessData],
        cellStats: [CellStats]
    ) throws {
        guard var table = outputs["collimation_map"] as? TableData else { return }

        var df = DataFrame()
        df.append(column: Column(name: "cell_id",              contents: cellStats.map(\.cellID)))
        df.append(column: Column(name: "grid_col",             contents: cellStats.map(\.gridCol)))
        df.append(column: Column(name: "grid_row",             contents: cellStats.map(\.gridRow)))
        df.append(column: Column(name: "cell_center_x",        contents: cellStats.map(\.cellCenterX)))
        df.append(column: Column(name: "cell_center_y",        contents: cellStats.map(\.cellCenterY)))
        df.append(column: Column(name: "donut_count",          contents: cellStats.map(\.donutCount)))
        df.append(column: Column(name: "mean_offset_x",        contents: cellStats.map(\.meanOffsetX)))
        df.append(column: Column(name: "mean_offset_y",        contents: cellStats.map(\.meanOffsetY)))
        df.append(column: Column(name: "mean_offset_magnitude",contents: cellStats.map(\.meanOffsetMagnitude)))
        df.append(column: Column(name: "mean_offset_angle",    contents: cellStats.map(\.meanOffsetAngle)))

        table.dataFrame = df
        outputs["collimation_map"] = table
    }

    private func writeSummaryTable(
        outputs: inout [String: ProcessData],
        summary: SummaryStats
    ) throws {
        guard var table = outputs["collimation_summary"] as? TableData else { return }

        var df = DataFrame()
        df.append(column: Column(name: "total_donuts",              contents: [summary.totalDonuts]))
        df.append(column: Column(name: "collimation_offset_x",     contents: [summary.offsetX]))
        df.append(column: Column(name: "collimation_offset_y",     contents: [summary.offsetY]))
        df.append(column: Column(name: "collimation_offset_magnitude", contents: [summary.offsetMagnitude]))
        df.append(column: Column(name: "collimation_offset_angle", contents: [summary.offsetAngle]))
        df.append(column: Column(name: "offset_uniformity",        contents: [summary.offsetUniformity]))
        df.append(column: Column(name: "diagnosis",                contents: [summary.diagnosis]))

        table.dataFrame = df
        outputs["collimation_summary"] = table
    }
}
