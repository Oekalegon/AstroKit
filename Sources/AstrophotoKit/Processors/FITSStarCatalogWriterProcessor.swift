import Foundation
import Metal
import TabularData
import os

/// Appends a STARCATALOG BINTABLE to the source FITS file of the input frame
/// and writes star quality statistics (NSTARS, MEDFWHM, MEANFWHM, MEANECC)
/// into its primary HDU header.
///
/// This processor is a side-effect step: it modifies the source FITS file in-place
/// and produces no pipeline outputs.  If the input frame has no file path (e.g. it
/// is an in-memory intermediate frame) the step is skipped without error.
public struct FITSStarCatalogWriterProcessor: Processor {

    public var id: String { "fits_star_catalog_writer" }

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
            Logger.processor.info("FITSStarCatalogWriter: no file path on input frame, skipping.")
            return
        }

        let starDF = try validatedStarDataFrame(from: inputs)
        let (medianMajor, medianMinor, meanMajor, meanMinor) = fwhmStatistics(from: inputs)
        let meanEcc = meanEccentricity(from: starDF)

        try FITSTableWriter.appendStarCatalog(
            starDF,
            medianFWHMMajor: medianMajor,
            medianFWHMMinor: medianMinor,
            meanFWHMMajor: meanMajor,
            meanFWHMMinor: meanMinor,
            meanEccentricity: meanEcc,
            to: filePath
        )
    }

    // MARK: - Private helpers

    private func validatedStarDataFrame(from inputs: [String: ProcessData]) throws -> DataFrame {
        guard let table = inputs["pixel_coordinates"] as? TableData,
              let df = table.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("pixel_coordinates")
        }
        return df
    }

    /// Reads statistics from the `median_fwhm` table produced by FWHMProcessor.
    private func fwhmStatistics(from inputs: [String: ProcessData]) -> (Double, Double, Double, Double) {
        guard let table = inputs["median_fwhm"] as? TableData,
              let df = table.dataFrame,
              !df.rows.isEmpty else {
            return (0.0, 0.0, 0.0, 0.0)
        }
        let row = df.rows[0]
        let medMaj  = (row["median_fwhm_major"]             as? Double) ?? 0.0
        let medMin  = (row["median_fwhm_minor"]             as? Double) ?? 0.0
        let meanMaj = (row["sigma_clipped_mean_fwhm_major"] as? Double) ?? 0.0
        let meanMin = (row["sigma_clipped_mean_fwhm_minor"] as? Double) ?? 0.0
        return (medMaj, medMin, meanMaj, meanMin)
    }

    /// Computes the mean eccentricity across non-saturated stars.
    private func meanEccentricity(from df: DataFrame) -> Double {
        var sum = 0.0
        var count = 0
        for rowIndex in 0..<df.rows.count {
            let row = df.rows[rowIndex]
            let isSaturated = (row["saturated"] as? Bool) == true
            guard !isSaturated,
                  let ecc = row["eccentricity"] as? Double,
                  ecc >= 0 else { continue }
            sum += ecc
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0.0
    }
}
