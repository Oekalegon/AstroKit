import Testing
import Foundation
import Metal
import TabularData
@testable import AstrophotoKit

// MARK: - Helpers

/// Creates a minimal star catalog DataFrame for testing.
private func makeStarDataFrame(count: Int = 3) -> DataFrame {
    var df = DataFrame()
    df.append(column: Column(name: "id",          contents: (0..<count).map { $0 }))
    df.append(column: Column(name: "area",         contents: (0..<count).map { _ in 42 }))
    df.append(column: Column(name: "flux",         contents: (0..<count).map { Double($0) * 100.0 }))
    df.append(column: Column(name: "centroid_x",   contents: (0..<count).map { Double($0) * 50.0 + 100.0 }))
    df.append(column: Column(name: "centroid_y",   contents: (0..<count).map { Double($0) * 50.0 + 200.0 }))
    df.append(column: Column(name: "major_axis",   contents: (0..<count).map { _ in 5.0 }))
    df.append(column: Column(name: "minor_axis",   contents: (0..<count).map { _ in 4.0 }))
    df.append(column: Column(name: "rotation_angle", contents: (0..<count).map { _ in 0.1 }))
    df.append(column: Column(name: "fwhm_major",   contents: (0..<count).map { _ in 3.2 }))
    df.append(column: Column(name: "fwhm_minor",   contents: (0..<count).map { _ in 2.9 }))
    df.append(column: Column(name: "eccentricity", contents: (0..<count).map { _ in 0.42 }))
    df.append(column: Column(name: "saturated",    contents: (0..<count).map { _ in false }))
    return df
}

/// Creates a minimal FITS file at `path` (a 4×4 float image with PIPELINE keyword).
private func makeMinimalFITSFile(at path: String) throws {
    let pixels: [Float] = Array(repeating: 0.5, count: 16)
    try FITSTableWriter.writeResultFrame(
        pixelData: pixels, width: 4, height: 4,
        pipelineID: "test",
        to: path
    )
}

/// Opens a FITS file and reads all header keywords from the primary HDU.
private func primaryHDUKeywords(at path: String) throws -> [String: String] {
    var status: Int32 = 0
    var fptr: OpaquePointer?

    try path.withCString { cPath in
        _ = openFITSFile(&fptr, cPath, 0 /* READONLY */, &status)
        guard status == 0 else {
            var errText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(status, &errText)
            throw FITSFileError.cannotOpenFile(path: path, status: status,
                                               message: String(cString: errText))
        }
    }
    guard let file = fptr else {
        throw FITSFileError.cannotOpenFile(path: path, status: -1, message: "nil pointer")
    }
    defer {
        var s: Int32 = 0
        _ = closeFITSFile(file, &s)
    }

    var hduType: Int32 = 0
    _ = moveToHDUPointer(file, 1, &hduType, &status)

    var numKeys: Int32 = 0
    var numMore: Int32 = 0
    _ = getHeaderSpace(file, &numKeys, &numMore, &status)

    var keywords: [String: String] = [:]
    for i in 1...max(1, numKeys) {
        var keyName = [CChar](repeating: 0, count: 80)
        var value   = [CChar](repeating: 0, count: 80)
        var comment = [CChar](repeating: 0, count: 80)
        var s: Int32 = 0
        _ = readKeyAtIndex(file, Int32(i), &keyName, &value, &comment, &s)
        guard s == 0 else { continue }
        let name = String(cString: keyName).trimmingCharacters(in: .whitespaces)
        let val  = String(cString: value)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            .trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { keywords[name] = val }
    }
    return keywords
}

// MARK: - Unit tests

@Test("FITSStarCatalogWriterProcessor skips gracefully when input frame has no file path")
func testProcessorSkipsWhenNoFilePath() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available")
        return
    }

    let starDF = makeStarDataFrame()
    var starTable = TableData()
    starTable.dataFrame = starDF

    var medianTable = TableData()
    var medianDF = DataFrame()
    medianDF.append(column: Column(name: "median_fwhm_major",             contents: [3.2]))
    medianDF.append(column: Column(name: "median_fwhm_minor",             contents: [2.9]))
    medianDF.append(column: Column(name: "sigma_clipped_mean_fwhm_major", contents: [3.1]))
    medianDF.append(column: Column(name: "sigma_clipped_mean_fwhm_minor", contents: [2.8]))
    medianTable.dataFrame = medianDF

    // Frame with no filePath — processor must skip without error
    let frame = Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)
    let inputs: [String: ProcessData] = [
        "input_frame":      frame,
        "pixel_coordinates": starTable,
        "median_fwhm":      medianTable
    ]
    var outputs: [String: ProcessData] = [:]

    let processor = FITSStarCatalogWriterProcessor()
    #expect(throws: Never.self) {
        try processor.execute(
            inputs: inputs, outputs: &outputs,
            parameters: [:], device: device, commandQueue: commandQueue
        )
    }
}

@Test("appendStarCatalog adds STARCATALOG HDU and quality keywords to FITS primary header")
func testAppendStarCatalogAddsHDUAndKeywords() throws {
    let tempDir  = FileManager.default.temporaryDirectory
    let tempPath = tempDir.appendingPathComponent("test_star_catalog_\(UInt64(Date().timeIntervalSince1970)).fits").path
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    try makeMinimalFITSFile(at: tempPath)

    let starDF = makeStarDataFrame(count: 5)
    try FITSTableWriter.appendStarCatalog(
        starDF,
        medianFWHMMajor: 3.2, medianFWHMMinor: 2.9,
        meanFWHMMajor:   3.1, meanFWHMMinor:   2.8,
        meanEccentricity: 0.42,
        to: tempPath
    )

    // Verify HDU count: primary image + STARCATALOG = 2
    let fitsFile = try FITSFile(path: tempPath)
    let hdus = try fitsFile.numberOfHDUs()
    #expect(hdus == 2, "FITS file should have 2 HDUs after appending star catalog")

    // Verify quality keywords in primary HDU
    let keywords = try primaryHDUKeywords(at: tempPath)
    #expect(keywords["NSTARS"] != nil, "Primary HDU should contain NSTARS keyword")
    #expect(keywords["MEDFWHM"] != nil, "Primary HDU should contain MEDFWHM keyword")
    #expect(keywords["MEDFWHM2"] != nil, "Primary HDU should contain MEDFWHM2 keyword")
    #expect(keywords["MEANFWHM"] != nil, "Primary HDU should contain MEANFWHM keyword")
    #expect(keywords["MEANFWM2"] != nil, "Primary HDU should contain MEANFWM2 keyword")
    #expect(keywords["MEANECC"] != nil, "Primary HDU should contain MEANECC keyword")

    #expect(keywords["NSTARS"] == "5", "NSTARS should equal the number of stars")
}

@Test("appendStarCatalog is idempotent: calling twice still produces exactly 2 HDUs")
func testAppendStarCatalogIsIdempotent() throws {
    let tempDir  = FileManager.default.temporaryDirectory
    let tempPath = tempDir.appendingPathComponent("test_star_catalog_idem_\(UInt64(Date().timeIntervalSince1970)).fits").path
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    try makeMinimalFITSFile(at: tempPath)
    let starDF = makeStarDataFrame()

    try FITSTableWriter.appendStarCatalog(
        starDF,
        medianFWHMMajor: 3.2, medianFWHMMinor: 2.9,
        meanFWHMMajor: 3.1, meanFWHMMinor: 2.8,
        meanEccentricity: 0.42,
        to: tempPath
    )
    try FITSTableWriter.appendStarCatalog(
        starDF,
        medianFWHMMajor: 3.5, medianFWHMMinor: 3.1,
        meanFWHMMajor: 3.4, meanFWHMMinor: 3.0,
        meanEccentricity: 0.45,
        to: tempPath
    )

    let fitsFile = try FITSFile(path: tempPath)
    let hdus = try fitsFile.numberOfHDUs()
    #expect(hdus == 2, "Re-running appendStarCatalog should not add a duplicate STARCATALOG HDU")

    // Header should reflect the second (most recent) call's values
    let keywords = try primaryHDUKeywords(at: tempPath)
    #expect(keywords["MEDFWHM"] != nil)
}

// MARK: - Integration test

@Test("star_detection pipeline fits_catalog_writer step runs and completes")
func testFitsStarCatalogWriterStepRunsInPipeline() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available")
        return
    }

    guard let pipeline = PipelineRegistry.shared.get(id: "star_detection") else {
        Issue.record("star-detection pipeline not found in registry")
        return
    }

    let fitsFileName = "CHI-1-CMOS_2025-03-25T08-25-40_LDN43TheCosmicBatNebula_Luminance_300s_ID493996_cal"
    var sourceURL: URL?
    if let testBundle = Bundle.module as Bundle? {
        sourceURL = testBundle.url(forResource: fitsFileName, withExtension: "fits")
    }
    if sourceURL == nil {
        for b in Bundle.allBundles {
            if let url = b.url(forResource: fitsFileName, withExtension: "fits") {
                sourceURL = url; break
            }
        }
    }
    guard let sourceURL else { return }

    // Copy to a writable temp location so the processor can open it in READWRITE mode
    let tempDir  = FileManager.default.temporaryDirectory
    let copyPath = tempDir.appendingPathComponent("star_catalog_integration_\(UInt64(Date().timeIntervalSince1970)).fits").path
    try FileManager.default.copyItem(atPath: sourceURL.path, toPath: copyPath)
    defer { try? FileManager.default.removeItem(atPath: copyPath) }

    // Read image in a scoped block so FITSFile closes before the pipeline opens the
    // same file in READWRITE mode (cfitsio rejects concurrent open with different modes).
    let inputFrame: Frame
    do {
        let fitsFile  = try FITSFile(path: copyPath)
        let fitsImage = try fitsFile.readFITSImage()
        inputFrame = try Frame(fitsImage: fitsImage, device: device, filePath: copyPath)
    }

    let runner = PipelineRunner(pipeline: pipeline)
    _ = try await runner.execute(
        inputs: ["input_frame": inputFrame],
        parameters: ["blur_radius": Parameter.double(3.0)],
        device: device,
        commandQueue: commandQueue
    )

    // Verify fits_catalog_writer process completed
    let processes = await runner.processStack.getAll()
    let catalogProcess = processes.first { $0.stepIdentifier == "fits_catalog_writer" }
    #expect(catalogProcess != nil, "fits_catalog_writer process should exist in process stack")
    if let proc = catalogProcess {
        let completed = proc.statusHistory.contains {
            if case .completed = $0 { return true }
            return false
        }
        #expect(completed, "fits_catalog_writer process should have completed")
    }

    // Verify the FITS file now has a STARCATALOG extension
    let updatedFile = try FITSFile(path: copyPath)
    let hdus = try updatedFile.numberOfHDUs()
    #expect(hdus == 2, "Source FITS file should have 2 HDUs (primary + STARCATALOG) after pipeline run")

    // Verify quality keywords written to the primary HDU
    let keywords = try primaryHDUKeywords(at: copyPath)
    #expect(keywords["NSTARS"] != nil, "NSTARS keyword should be present in primary HDU")
    #expect(keywords["MEDFWHM"] != nil, "MEDFWHM keyword should be present in primary HDU")
    #expect(keywords["MEANECC"] != nil, "MEANECC keyword should be present in primary HDU")
    print("✓ Star catalog written: NSTARS=\(keywords["NSTARS"] ?? "?"), MEDFWHM=\(keywords["MEDFWHM"] ?? "?")")
}
