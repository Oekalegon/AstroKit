import Foundation
import Metal
import TabularData
import os

/// Writes the frame_quality summary metrics (NSTARS, SATSTARS, MEDFWHM,
/// MEDECC, BACKNOIS) into the primary HDU header of the input frame's source
/// FITS file. These are the keywords FITSHeaderReader reads back when the
/// file is (re-)imported into the archive.
///
/// This processor is a side-effect step: it modifies the source FITS file
/// in-place and produces no pipeline outputs. If the input frame has no file
/// path (e.g. it is an in-memory intermediate frame) the step is skipped
/// without error. Repeated runs overwrite the keywords in place (idempotent).
public struct FITSQualityWriterProcessor: Processor {

    public var id: String { "fits_quality_writer" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let inputFrame = inputs["input_frame"] as? Frame else {
            throw ProcessorExecutionError.missingRequiredInput("input_frame")
        }
        guard let filePath = inputFrame.filePath else {
            Logger.processor.info("FITSQualityWriter: no file path on input frame, skipping.")
            return
        }
        guard let table = inputs["frame_quality"] as? TableData,
              let df = table.dataFrame,
              let row = df.rows.first else {
            throw ProcessorExecutionError.missingRequiredInput("frame_quality")
        }

        let starCount = intValue(row["star_count"])
        let saturated = intValue(row["saturated_star_count"])
        // median_fwhm / median_eccentricity are written as 0.0 by the quality
        // processor when no stars were measured — treat those as unavailable.
        let hasStars = (starCount ?? 0) > 0
        let medianFWHM = (row["median_fwhm"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        let medianEcc  = hasStars ? row["median_eccentricity"] as? Double : nil
        let backgroundADU = row["background_level_adu"] as? Double

        // Celestial context (optional — absent when headers lacked lat/lon or RA/Dec)
        var sunAltDeg: Double? = nil
        var moonSepDeg: Double? = nil
        var moonIllum: Double? = nil
        if let celestialTable = inputs["celestial_context"] as? TableData,
           let cdf = celestialTable.dataFrame,
           let crow = cdf.rows.first {
            let cCols = Set(cdf.columns.map { $0.name })
            if cCols.contains("sun_altitude_deg")    { sunAltDeg   = crow["sun_altitude_deg"]    as? Double }
            if cCols.contains("moon_separation_deg") { moonSepDeg = crow["moon_separation_deg"] as? Double }
            if cCols.contains("moon_illumination")   { moonIllum   = crow["moon_illumination"]   as? Double }
        }

        try FITSTableWriter.writeQualityKeys(
            starCount: starCount,
            saturatedStarCount: saturated,
            medianFWHM: medianFWHM,
            medianEccentricity: medianEcc,
            backgroundADU: backgroundADU,
            sunAltitudeDeg: sunAltDeg,
            moonSeparationDeg: moonSepDeg,
            moonIllumination: moonIllum,
            to: filePath
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int   { return v }
        if let v = value as? Int32 { return Int(v) }
        return nil
    }
}
