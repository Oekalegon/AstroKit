import Foundation
import TabularData
import CCFITSIO
import os

@_silgen_name("write_stacked_fits")
private func writeStackedFITSC(
    _ filename: UnsafePointer<CChar>,
    _ imageData: UnsafeMutablePointer<Float>,
    _ width: Int32,
    _ height: Int32,
    // registration table
    _ nrows: Int32,
    _ frameIndex: UnsafeMutablePointer<Int32>,
    _ filePaths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ timestamps: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ exposures: UnsafeMutablePointer<Double>,
    _ filterNames: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ gains: UnsafeMutablePointer<Double>,
    _ offsetVals: UnsafeMutablePointer<Double>,
    _ frameTypes: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ translationX: UnsafeMutablePointer<Double>,
    _ translationY: UnsafeMutablePointer<Double>,
    _ rotationDeg: UnsafeMutablePointer<Double>,
    _ scale: UnsafeMutablePointer<Double>,
    _ matchCount: UnsafeMutablePointer<Int32>,
    _ rmse: UnsafeMutablePointer<Double>,
    _ starCount: UnsafeMutablePointer<Int32>,
    _ meanFWHM: UnsafeMutablePointer<Double>,
    _ medianFWHM: UnsafeMutablePointer<Double>,
    _ meanEccentricity: UnsafeMutablePointer<Double>,
    _ meanPositionAngle: UnsafeMutablePointer<Double>,
    _ meanFlux: UnsafeMutablePointer<Double>,
    _ skyBackground: UnsafeMutablePointer<Double>,
    _ skyNoise: UnsafeMutablePointer<Double>,
    _ referenceFrame: Int32,
    // stacking metadata for FITS header
    _ totalExposure: Double,
    _ filterName: UnsafePointer<CChar>,
    _ gain: Double,
    _ offsetVal: Double,
    _ dateObs: UnsafePointer<CChar>,
    _ stackMethod: UnsafePointer<CChar>,
    _ normalisation: UnsafePointer<CChar>,
    _ rejection: UnsafePointer<CChar>,
    _ rejLow: Double,
    _ rejHigh: Double,
    _ stackedSkyBkg: Double,
    _ stackedSkyNoise: Double,
    _ statusOut: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("write_result_frame_fits")
private func writeResultFrameFITSC(
    _ filename: UnsafePointer<CChar>,
    _ pixels: UnsafeMutablePointer<Float>,
    _ width: Int32,
    _ height: Int32,
    _ pipelineID: UnsafePointer<CChar>,
    _ imageType: UnsafePointer<CChar>,
    _ filterName: UnsafePointer<CChar>,
    _ stacked: Int32,
    _ nframes: Int32,
    _ totalExposure: Double,
    _ gain: Double,
    _ offsetVal: Double,
    _ temperature: Double,
    _ objectName: UnsafePointer<CChar>,
    _ camera: UnsafePointer<CChar>,
    _ ra: Double,
    _ dec: Double,
    _ pixelScale: Double,
    _ focalLength: Double,
    _ tempMin: Double,
    _ tempMax: Double,
    _ dateObs: UnsafePointer<CChar>,
    _ dateBeg: UnsafePointer<CChar>,
    _ dateEnd: UnsafePointer<CChar>,
    _ isMaster: Int32,
    _ statusOut: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("append_star_catalog_to_fits")
private func appendStarCatalogToFITSC(
    _ filename: UnsafePointer<CChar>,
    _ nrows: Int32,
    _ starID: UnsafeMutablePointer<Int32>,
    _ centroidX: UnsafeMutablePointer<Double>,
    _ centroidY: UnsafeMutablePointer<Double>,
    _ fwhmMajor: UnsafeMutablePointer<Double>,
    _ fwhmMinor: UnsafeMutablePointer<Double>,
    _ eccentricity: UnsafeMutablePointer<Double>,
    _ flux: UnsafeMutablePointer<Double>,
    _ area: UnsafeMutablePointer<Int32>,
    _ saturated: UnsafeMutablePointer<Int32>,
    _ medianFWHMMajor: Double,
    _ medianFWHMMinor: Double,
    _ meanFWHMMajor: Double,
    _ meanFWHMMinor: Double,
    _ meanEccentricity: Double,
    _ nStars: Int32,
    _ statusOut: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("write_registration_fits_table")
private func writeRegistrationFITSTableC(
    _ filename: UnsafePointer<CChar>,
    _ nrows: Int32,
    _ frameIndex: UnsafeMutablePointer<Int32>,
    _ filePaths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ timestamps: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ exposures: UnsafeMutablePointer<Double>,
    _ filterNames: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ gains: UnsafeMutablePointer<Double>,
    _ offsetVals: UnsafeMutablePointer<Double>,
    _ frameTypes: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ translationX: UnsafeMutablePointer<Double>,
    _ translationY: UnsafeMutablePointer<Double>,
    _ rotationDeg: UnsafeMutablePointer<Double>,
    _ scale: UnsafeMutablePointer<Double>,
    _ matchCount: UnsafeMutablePointer<Int32>,
    _ rmse: UnsafeMutablePointer<Double>,
    _ starCount: UnsafeMutablePointer<Int32>,
    _ meanFWHM: UnsafeMutablePointer<Double>,
    _ medianFWHM: UnsafeMutablePointer<Double>,
    _ meanEccentricity: UnsafeMutablePointer<Double>,
    _ meanPositionAngle: UnsafeMutablePointer<Double>,
    _ meanFlux: UnsafeMutablePointer<Double>,
    _ skyBackground: UnsafeMutablePointer<Double>,
    _ skyNoise: UnsafeMutablePointer<Double>,
    _ referenceFrame: Int32,
    _ statusOut: UnsafeMutablePointer<Int32>
) -> Int32

/// Writes pipeline table outputs to disk in FITS or CSV format.
public struct FITSTableWriter {

    public enum OutputFormat {
        case fits
        case csv
    }

    /// Write a registration DataFrame to disk.
    /// - Parameters:
    ///   - df: The registration DataFrame (must contain the standard registration columns).
    ///   - path: Destination file path.
    ///   - format: `.fits` (BINTABLE extension) or `.csv`.
    public static func writeRegistrationTable(
        _ df: DataFrame,
        to path: String,
        format: OutputFormat = .fits
    ) throws {
        switch format {
        case .csv:
            try writeCSV(df, to: path)
        case .fits:
            try writeFITS(df, to: path)
        }
    }

    /// Write a stacked image + registration table to a FITS file.
    ///
    /// The primary HDU is a 32-bit float image with full FITS header metadata
    /// (IMAGETYP, NFRAMES, EXPTIME, FILTER, GAIN, DATE-OBS, stacking keywords).
    /// A REGISTRATION BINTABLE extension carries the per-frame registration data.
    /// - Parameters:
    ///   - pixelData: Row-major float32 pixel values (row 0 = top).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - registrationTable: DataFrame from the frame_registration_quad step.
    ///   - method: Combine method used (e.g. "average", "median").
    ///   - normalisation: Normalisation method used.
    ///   - rejection: Pixel rejection method used.
    ///   - rejectionLow: Lower rejection sigma.
    ///   - rejectionHigh: Upper rejection sigma.
    ///   - path: Destination file path.
    public static func writeStackedOutput(
        pixelData: [Float],
        width: Int,
        height: Int,
        registrationTable df: DataFrame,
        method: String = "average",
        normalisation: String = "none",
        rejection: String = "sigma_clip",
        rejectionLow: Double = 3.0,
        rejectionHigh: Double = 3.0,
        to path: String
    ) throws {
        let nrows = Int32(df.rows.count)

        func doubles(_ col: String) -> [Double] {
            df.rows.map { ($0[col] as? Double) ?? 0 }
        }
        func optionalDoubles(_ col: String) -> [Double] {
            df.rows.map { ($0[col] as? Double) ?? Double.nan }
        }
        func ints(_ col: String) -> [Int32] {
            df.rows.map { row -> Int32 in
                if let v = row[col] as? Int32 { return v }
                if let v = row[col] as? Int   { return Int32(v) }
                return 0
            }
        }
        func strings(_ col: String) -> [String] {
            guard df.columns.contains(where: { $0.name == col }) else {
                return Array(repeating: "", count: Int(nrows))
            }
            return df.rows.map { ($0[col] as? String) ?? "" }
        }

        var frameIndex        = ints("frame_index")
        var translationX      = doubles("translation_x")
        var translationY      = doubles("translation_y")
        var rotationDeg       = doubles("rotation_deg")
        var scale             = doubles("scale")
        var matchCount        = ints("match_count")
        var rmse              = doubles("rmse")
        var starCount         = ints("star_count")
        var meanFWHM          = doubles("mean_fwhm")
        var medianFWHM        = doubles("median_fwhm")
        var meanEccentricity  = doubles("mean_eccentricity")
        var meanPositionAngle = doubles("mean_position_angle")
        var meanFlux          = doubles("mean_flux")
        var skyBackground     = doubles("sky_background")
        var skyNoise          = doubles("sky_noise")
        var exposures         = optionalDoubles("exposure")
        var gains             = optionalDoubles("gain")
        var offsetVals        = optionalDoubles("offset")

        var cFilePaths   = strings("file_path").map   { strdup($0) }
        var cTimestamps  = strings("timestamp").map   { strdup($0) }
        var cFilterNames = strings("filter").map      { strdup($0) }
        var cFrameTypes  = strings("frame_type").map  { strdup($0) }
        defer {
            cFilePaths.forEach   { free($0) }
            cTimestamps.forEach  { free($0) }
            cFilterNames.forEach { free($0) }
            cFrameTypes.forEach  { free($0) }
        }

        let refOffset = frameIndex.enumerated().first { i, _ in
            abs(translationX[i]) < 1e-9 && abs(translationY[i]) < 1e-9
        }?.offset ?? 0
        let refFrameIdx = Int32(refOffset)

        // --- Derive header metadata from the registration table ---

        // Total integration time: sum of all valid per-frame exposures
        let totalExposure = exposures
            .filter { !$0.isNaN && $0 > 0 }
            .reduce(0, +)

        // Filter: from the reference frame (or first non-empty)
        let refFilter = df.rows
            .first { row in
                let idx = row["frame_index"] as? Int32 ?? -1
                return Int(idx) == refOffset
            }
            .flatMap { $0["filter"] as? String }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? strings("filter").first { !$0.isEmpty }
            ?? ""

        // Gain / offset: from the reference frame (-1.0 = unknown)
        let refGain: Double = {
            let v = gains.indices.contains(refOffset) ? gains[refOffset] : Double.nan
            return v.isNaN ? -1.0 : v
        }()
        let refOffset_val: Double = {
            let v = offsetVals.indices.contains(refOffset) ? offsetVals[refOffset] : Double.nan
            return v.isNaN ? -1.0 : v
        }()

        // Earliest observation timestamp
        let dateObs = strings("timestamp")
            .filter { !$0.isEmpty }
            .sorted()
            .first ?? ""

        var pixels = pixelData

        // Noise of the stacked image: NMAD on a strided sample.
        // median(pixels) → sky background; 1.4826 × median(|x − bg|) → σ_sky.
        let stackedSkyBkg: Double
        let stackedSkyNoise: Double
        do {
            let step = max(1, pixels.count / 65536)
            var sample = [Double]()
            sample.reserveCapacity(pixels.count / step + 1)
            var idx = 0
            while idx < pixels.count { sample.append(Double(pixels[idx])); idx += step }
            sample.sort()
            let bg = sample[sample.count / 2]
            var devs = sample.map { abs($0 - bg) }
            devs.sort()
            stackedSkyBkg   = bg
            stackedSkyNoise = 1.4826 * devs[devs.count / 2]
        }

        var statusOut: Int32 = 0

        _ = path.withCString { cPath in
        method.withCString { cMethod in
        normalisation.withCString { cNorm in
        rejection.withCString { cRej in
        refFilter.withCString { cFilter in
        dateObs.withCString { cDateObs in
            pixels.withUnsafeMutableBufferPointer { imgBuf in
            frameIndex.withUnsafeMutableBufferPointer { fi in
            translationX.withUnsafeMutableBufferPointer { tx in
            translationY.withUnsafeMutableBufferPointer { ty in
            rotationDeg.withUnsafeMutableBufferPointer { rd in
            scale.withUnsafeMutableBufferPointer { sc in
            matchCount.withUnsafeMutableBufferPointer { mc in
            rmse.withUnsafeMutableBufferPointer { rm in
            starCount.withUnsafeMutableBufferPointer { stc in
            meanFWHM.withUnsafeMutableBufferPointer { mf in
            medianFWHM.withUnsafeMutableBufferPointer { mdf in
            meanEccentricity.withUnsafeMutableBufferPointer { me in
            meanPositionAngle.withUnsafeMutableBufferPointer { mp in
            meanFlux.withUnsafeMutableBufferPointer { mfl in
            skyBackground.withUnsafeMutableBufferPointer { sbg in
            skyNoise.withUnsafeMutableBufferPointer { sn in
            exposures.withUnsafeMutableBufferPointer { exp in
            gains.withUnsafeMutableBufferPointer { gn in
            offsetVals.withUnsafeMutableBufferPointer { ov in
            cFilePaths.withUnsafeMutableBufferPointer { fp in
            cTimestamps.withUnsafeMutableBufferPointer { ts in
            cFilterNames.withUnsafeMutableBufferPointer { fn in
            cFrameTypes.withUnsafeMutableBufferPointer { ft in
                writeStackedFITSC(
                    cPath,
                    imgBuf.baseAddress!, Int32(width), Int32(height),
                    nrows,
                    fi.baseAddress!, fp.baseAddress!, ts.baseAddress!, exp.baseAddress!,
                    fn.baseAddress!, gn.baseAddress!, ov.baseAddress!, ft.baseAddress!,
                    tx.baseAddress!, ty.baseAddress!, rd.baseAddress!, sc.baseAddress!,
                    mc.baseAddress!, rm.baseAddress!, stc.baseAddress!,
                    mf.baseAddress!, mdf.baseAddress!, me.baseAddress!,
                    mp.baseAddress!, mfl.baseAddress!,
                    sbg.baseAddress!, sn.baseAddress!,
                    refFrameIdx,
                    totalExposure, cFilter, refGain, refOffset_val, cDateObs,
                    cMethod, cNorm, cRej, rejectionLow, rejectionHigh,
                    stackedSkyBkg, stackedSkyNoise,
                    &statusOut
                )
            }}}}}}}}}}}}}}}}}}}}}}}}}}}}}

        if statusOut != 0 {
            var errText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(statusOut, &errText)
            errText[80] = 0
            throw FITSTableWriterError.writeFailed(String(cString: errText))
        }
        Logger.swiftfitsio.info("Wrote stacked FITS to \(path)")
    }

    /// Write a result frame to a minimal FITS primary-HDU image file.
    ///
    /// Used for auto-archiving pipeline output frames that are not otherwise
    /// saved via `writeStackedOutput`. Produces a 32-bit float image with a
    /// small set of processing provenance keywords in the FITS header.
    public static func writeResultFrame(
        pixelData: [Float],
        width: Int,
        height: Int,
        pipelineID: String,
        imageType: String = "Light Frame",
        filterName: String? = nil,
        stacked: Bool = false,
        isMaster: Bool = false,
        nframes: Int? = nil,
        totalExposure: Double? = nil,
        gain: Double? = nil,
        offset: Double? = nil,
        temperature: Double? = nil,
        objectName: String? = nil,
        camera: String? = nil,
        ra: Double? = nil,
        dec: Double? = nil,
        pixelScale: Double? = nil,
        focalLength: Double? = nil,
        tempMin: Double? = nil,
        tempMax: Double? = nil,
        dateObs: String? = nil,
        dateBeg: String? = nil,
        dateEnd: String? = nil,
        to path: String
    ) throws {
        var pixels = pixelData
        var statusOut: Int32 = 0
        path.withCString { cPath in
        pipelineID.withCString { cPipeline in
        imageType.withCString { cType in
        (filterName ?? "").withCString { cFilter in
        (objectName ?? "").withCString { cObject in
        (camera ?? "").withCString { cCamera in
        (dateObs ?? "").withCString { cDateObs in
        (dateBeg ?? "").withCString { cDateBeg in
        (dateEnd ?? "").withCString { cDateEnd in
            pixels.withUnsafeMutableBufferPointer { buf in
                _ = writeResultFrameFITSC(
                    cPath, buf.baseAddress!,
                    Int32(width), Int32(height),
                    cPipeline, cType, cFilter,
                    stacked ? 1 : 0,
                    Int32(nframes ?? 0),
                    totalExposure ?? .nan,
                    gain ?? .nan,
                    offset ?? .nan,
                    temperature ?? .nan,
                    cObject, cCamera,
                    ra ?? .nan, dec ?? .nan,
                    pixelScale ?? .nan, focalLength ?? .nan,
                    tempMin ?? .nan, tempMax ?? .nan,
                    cDateObs, cDateBeg, cDateEnd,
                    isMaster ? 1 : 0,
                    &statusOut
                )
            }
        }}}}}}}}}
        if statusOut != 0 {
            var errText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(statusOut, &errText)
            errText[80] = 0
            throw FITSTableWriterError.writeFailed(String(cString: errText))
        }
        Logger.swiftfitsio.info("Wrote result frame FITS to \(path)")
    }

    /// Append a STARCATALOG BINTABLE to an existing FITS file and write star
    /// quality statistics (NSTARS, MEDFWHM, MEANFWHM, MEANECC) into its primary HDU header.
    ///
    /// Any pre-existing STARCATALOG extension is replaced, making this idempotent.
    ///
    /// - Parameters:
    ///   - df: Star catalog DataFrame from the FWHM processor (pixel_coordinates output).
    ///   - medianFWHMMajor: Median FWHM along the major axis (pixels).
    ///   - medianFWHMMinor: Median FWHM along the minor axis (pixels).
    ///   - meanFWHMMajor: σ-clipped mean FWHM along the major axis (pixels).
    ///   - meanFWHMMinor: σ-clipped mean FWHM along the minor axis (pixels).
    ///   - meanEccentricity: Mean eccentricity across non-saturated stars.
    ///   - path: Path to the existing FITS file to update.
    public static func appendStarCatalog(
        _ df: DataFrame,
        medianFWHMMajor: Double,
        medianFWHMMinor: Double,
        meanFWHMMajor: Double,
        meanFWHMMinor: Double,
        meanEccentricity: Double,
        to path: String
    ) throws {
        let nrows = Int32(df.rows.count)

        func doubles(_ col: String) -> [Double] {
            df.rows.map { ($0[col] as? Double) ?? 0.0 }
        }
        func ints(_ col: String) -> [Int32] {
            df.rows.map { row -> Int32 in
                if let v = row[col] as? Int32 { return v }
                if let v = row[col] as? Int   { return Int32(v) }
                return 0
            }
        }

        var starID      = (0..<Int(nrows)).map { Int32($0) }
        var centroidX   = doubles("centroid_x")
        var centroidY   = doubles("centroid_y")
        var fwhmMajor   = doubles("fwhm_major")
        var fwhmMinor   = doubles("fwhm_minor")
        var eccentricity = doubles("eccentricity")
        var flux        = doubles("flux")
        var area        = ints("area")
        var saturated: [Int32] = df.rows.map { ($0["saturated"] as? Bool) == true ? 1 : 0 }

        var statusOut: Int32 = 0

        _ = path.withCString { cPath in
            starID.withUnsafeMutableBufferPointer { sid in
            centroidX.withUnsafeMutableBufferPointer { cx in
            centroidY.withUnsafeMutableBufferPointer { cy in
            fwhmMajor.withUnsafeMutableBufferPointer { fmaj in
            fwhmMinor.withUnsafeMutableBufferPointer { fmin in
            eccentricity.withUnsafeMutableBufferPointer { ecc in
            flux.withUnsafeMutableBufferPointer { fl in
            area.withUnsafeMutableBufferPointer { ar in
            saturated.withUnsafeMutableBufferPointer { sat in
                appendStarCatalogToFITSC(
                    cPath, nrows,
                    sid.baseAddress!, cx.baseAddress!, cy.baseAddress!,
                    fmaj.baseAddress!, fmin.baseAddress!, ecc.baseAddress!,
                    fl.baseAddress!, ar.baseAddress!, sat.baseAddress!,
                    medianFWHMMajor, medianFWHMMinor,
                    meanFWHMMajor, meanFWHMMinor,
                    meanEccentricity,
                    nrows,
                    &statusOut
                )
            }}}}}}}}}
        }

        if statusOut != 0 {
            var errText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(statusOut, &errText)
            errText[80] = 0
            throw FITSTableWriterError.writeFailed(String(cString: errText))
        }
        Logger.swiftfitsio.info("Appended star catalog to FITS file at \(path)")
    }

    /// Write any DataFrame as CSV using TabularData's built-in exporter.
    public static func writeCSV(_ df: DataFrame, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try df.writeCSV(to: url)
        Logger.swiftfitsio.info("Wrote CSV table to \(path)")
    }

    // MARK: - FITS BINTABLE writer

    private static func writeFITS(_ df: DataFrame, to path: String) throws {
        let nrows = Int32(df.rows.count)
        guard nrows > 0 else {
            throw FITSTableWriterError.emptyTable
        }

        func doubles(_ col: String) -> [Double] {
            df.rows.map { ($0[col] as? Double) ?? 0 }
        }
        func optionalDoubles(_ col: String) -> [Double] {
            df.rows.map { row -> Double in
                (row[col] as? Double) ?? Double.nan
            }
        }
        func ints(_ col: String) -> [Int32] {
            df.rows.map { row -> Int32 in
                if let v = row[col] as? Int32 { return v }
                if let v = row[col] as? Int   { return Int32(v) }
                return 0
            }
        }
        func strings(_ col: String) -> [String] {
            guard df.columns.contains(where: { $0.name == col }) else {
                return Array(repeating: "", count: Int(nrows))
            }
            return df.rows.map { ($0[col] as? String) ?? "" }
        }

        var frameIndex        = ints("frame_index")
        var translationX      = doubles("translation_x")
        var translationY      = doubles("translation_y")
        var rotationDeg       = doubles("rotation_deg")
        var scale             = doubles("scale")
        var matchCount        = ints("match_count")
        var rmse              = doubles("rmse")
        var starCount         = ints("star_count")
        var meanFWHM          = doubles("mean_fwhm")
        var medianFWHM        = doubles("median_fwhm")
        var meanEccentricity  = doubles("mean_eccentricity")
        var meanPositionAngle = doubles("mean_position_angle")
        var meanFlux          = doubles("mean_flux")
        var skyBackground     = doubles("sky_background")
        var skyNoise          = doubles("sky_noise")
        var exposures         = optionalDoubles("exposure")
        var gains             = optionalDoubles("gain")
        var offsetVals        = optionalDoubles("offset")

        // String columns — allocated as C strings; freed after the call
        var cFilePaths   = strings("file_path").map   { strdup($0) }
        var cTimestamps  = strings("timestamp").map   { strdup($0) }
        var cFilterNames = strings("filter").map      { strdup($0) }
        var cFrameTypes  = strings("frame_type").map  { strdup($0) }
        defer {
            cFilePaths.forEach   { free($0) }
            cTimestamps.forEach  { free($0) }
            cFilterNames.forEach { free($0) }
            cFrameTypes.forEach  { free($0) }
        }

        // Find reference frame (row where translation_x == 0 and translation_y == 0)
        let refFrameIdx = Int32(frameIndex.enumerated().first { i, _ in
            abs(translationX[i]) < 1e-9 && abs(translationY[i]) < 1e-9
        }?.offset ?? 0)

        var statusOut: Int32 = 0
        _ = path.withCString { cPath in
            frameIndex.withUnsafeMutableBufferPointer { fi in
            translationX.withUnsafeMutableBufferPointer { tx in
            translationY.withUnsafeMutableBufferPointer { ty in
            rotationDeg.withUnsafeMutableBufferPointer { rd in
            scale.withUnsafeMutableBufferPointer { sc in
            matchCount.withUnsafeMutableBufferPointer { mc in
            rmse.withUnsafeMutableBufferPointer { rm in
            starCount.withUnsafeMutableBufferPointer { stc in
            meanFWHM.withUnsafeMutableBufferPointer { mf in
            medianFWHM.withUnsafeMutableBufferPointer { mdf in
            meanEccentricity.withUnsafeMutableBufferPointer { me in
            meanPositionAngle.withUnsafeMutableBufferPointer { mp in
            meanFlux.withUnsafeMutableBufferPointer { mfl in
            skyBackground.withUnsafeMutableBufferPointer { sbg in
            skyNoise.withUnsafeMutableBufferPointer { sn in
            exposures.withUnsafeMutableBufferPointer { exp in
            gains.withUnsafeMutableBufferPointer { gn in
            offsetVals.withUnsafeMutableBufferPointer { ov in
            cFilePaths.withUnsafeMutableBufferPointer { fp in
            cTimestamps.withUnsafeMutableBufferPointer { ts in
            cFilterNames.withUnsafeMutableBufferPointer { fn in
            cFrameTypes.withUnsafeMutableBufferPointer { ft in
                writeRegistrationFITSTableC(
                    cPath, nrows,
                    fi.baseAddress!,
                    fp.baseAddress!, ts.baseAddress!, exp.baseAddress!,
                    fn.baseAddress!, gn.baseAddress!, ov.baseAddress!, ft.baseAddress!,
                    tx.baseAddress!, ty.baseAddress!, rd.baseAddress!, sc.baseAddress!,
                    mc.baseAddress!, rm.baseAddress!, stc.baseAddress!,
                    mf.baseAddress!, mdf.baseAddress!, me.baseAddress!,
                    mp.baseAddress!, mfl.baseAddress!,
                    sbg.baseAddress!, sn.baseAddress!,
                    refFrameIdx, &statusOut
                )
            }}}}}}}}}}}}}}}}}}}}}}
        }

        if statusOut != 0 {
            var errText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(statusOut, &errText)
            errText[80] = 0
            throw FITSTableWriterError.writeFailed(String(cString: errText))
        }
        Logger.swiftfitsio.info("Wrote FITS registration table to \(path)")
    }
}

// MARK: - IMAGETYP helpers

extension FITSTableWriter {
    /// Maps a pipeline YAML `frame_type` metadata value to the standard FITS IMAGETYP string.
    /// Master calibration types map to their raw equivalents; use `isMasterFrameType(_:)` to
    /// distinguish them and write the `ISMASTER` keyword.
    public static func fitsImageType(forFrameTypeMeta frameTypeMeta: String?) -> String {
        switch frameTypeMeta {
        case "masterBias":          return "Bias Frame"
        case "masterDark":          return "Dark Frame"
        case "masterDarkFlat":      return "Dark Flat"
        case "masterFlat":          return "Flat Field"
        case "calibratedDark":      return "Dark Frame"
        case "calibratedFlat":      return "Flat Field"
        case "calibratedDarkFlat":  return "Dark Flat"
        case "diagnostic":          return "Diagnostic Frame"
        default:                    return "Light Frame"
        }
    }

    /// Returns true for pipeline `frame_type` values that represent master calibration stacks.
    public static func isMasterFrameType(_ frameTypeMeta: String?) -> Bool {
        switch frameTypeMeta {
        case "masterBias", "masterDark", "masterDarkFlat", "masterFlat": return true
        default: return false
        }
    }

    /// Resolves the FITS IMAGETYP string for a result frame by reading the `frame_type`
    /// metadata declared on the matching output in the pipeline YAML definition.
    public static func resultFrameImageType(for frame: Frame, in pipeline: Pipeline) -> String {
        return fitsImageType(forFrameTypeMeta: frameTypeMeta(for: frame, in: pipeline))
    }

    /// Returns true when the result frame is a master calibration stack.
    public static func resultFrameIsMaster(for frame: Frame, in pipeline: Pipeline) -> Bool {
        return isMasterFrameType(frameTypeMeta(for: frame, in: pipeline))
    }

    private static func frameTypeMeta(for frame: Frame, in pipeline: Pipeline) -> String? {
        guard let outputLink = frame.outputLink,
              case .output(_, _, _, let stepLinkID) = outputLink else { return nil }
        let parts      = stepLinkID.split(separator: ".", maxSplits: 1)
        let stepPart   = String(parts.first ?? Substring(stepLinkID))
        let outputName = parts.count > 1 ? String(parts[1]) : ""
        let baseStepID = String(stepPart.split(separator: "[").first ?? Substring(stepPart))
        guard let step   = pipeline.steps.first(where: { $0.id == baseStepID }),
              let output = step.outputs.first(where: { $0.name == outputName }) else { return nil }
        return output.getMetadata()["frame_type"] as? String
    }
}

public enum FITSTableWriterError: Error, LocalizedError {
    case emptyTable
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTable:            return "Cannot write empty table"
        case .writeFailed(let msg):  return "FITS write failed: \(msg)"
        }
    }
}
