import Testing
import Foundation
import Metal
import TabularData
@testable import AstrophotoKit

// MARK: - AutofocusCurveProcessor Tests
// These tests are pure CPU (no Metal required for AutofocusCurveProcessor itself),
// but we pass a real Metal device for protocol conformance.

@Test("AutofocusCurveProcessor returns correct vertex for exact parabola data")
func testAutofocusCurveExactParabola() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    // hfd(p) = 0.001 * (p - 5000)^2 + 2.0 = 0.001*p^2 - 10*p + 27002
    let trueOptimal = 5000.0
    let positions = stride(from: 4600.0, through: 5400.0, by: 100.0).map { $0 }
    let hfdValues  = positions.map { 0.001 * ($0 - trueOptimal) * ($0 - trueOptimal) + 2.0 }

    var df = DataFrame()
    df.append(column: Column(name: "focuser_position", contents: positions))
    df.append(column: Column(name: "median_hfd",       contents: hfdValues))

    var measureTable = TableData()
    measureTable.dataFrame = df

    let processor = AutofocusCurveProcessor()
    let inputs: [String: ProcessData] = ["focus_measurements": measureTable]

    let resultTable = TableData()
    let curveTable  = TableData()
    var outputs: [String: ProcessData] = [
        "autofocus_result": resultTable,
        "fitted_curve":     curveTable
    ]

    try processor.execute(
        inputs: inputs,
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let result = (outputs["autofocus_result"] as? TableData)?.dataFrame
    #expect(result != nil, "autofocus_result table should be set")

    if let resultDF = result {
        let optimal = (resultDF.columns.first(where: { $0.name == "optimal_position" }))?[0] as? Double
        let rSq     = (resultDF.columns.first(where: { $0.name == "r_squared" }))?[0] as? Double
        let valid   = (resultDF.columns.first(where: { $0.name == "valid" }))?[0] as? Bool

        #expect(valid == true, "Fit should be valid for perfect parabola data")
        #expect(rSq != nil && rSq! > 0.999, "R² should be > 0.999 for exact parabola, got \(rSq ?? 0)")
        if let opt = optimal {
            #expect(abs(opt - trueOptimal) < 50.0, "Optimal position \(opt) should be within 50 of \(trueOptimal)")
        } else {
            Issue.record("optimal_position not found in result table")
        }
    }
}

@Test("AutofocusCurveProcessor rejects insufficient data")
func testAutofocusCurveInsufficientData() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    // Only 3 points — below default min_points = 5
    var df = DataFrame()
    df.append(column: Column(name: "focuser_position", contents: [100.0, 200.0, 300.0]))
    df.append(column: Column(name: "median_hfd",       contents: [5.0,   3.0,   5.0]))

    var measureTable = TableData()
    measureTable.dataFrame = df

    let processor = AutofocusCurveProcessor()
    let inputs: [String: ProcessData] = ["focus_measurements": measureTable]
    var outputs: [String: ProcessData] = [
        "autofocus_result": TableData(),
        "fitted_curve":     TableData()
    ]

    try processor.execute(
        inputs: inputs,
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let valid = ((outputs["autofocus_result"] as? TableData)?.dataFrame?["valid"] as? AnyColumn)?[0] as? Bool
    #expect(valid == false, "Should be invalid with only 3 data points")
}

@Test("AutofocusCurveProcessor rejects downward-opening parabola")
func testAutofocusCurveDownwardParabola() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    // hfd = -0.001 * (p - 5000)^2 + 10  — inverted (a < 0)
    let positions = stride(from: 4600.0, through: 5400.0, by: 100.0).map { $0 }
    let hfdValues = positions.map { -0.001 * ($0 - 5000) * ($0 - 5000) + 10.0 }

    var df = DataFrame()
    df.append(column: Column(name: "focuser_position", contents: positions))
    df.append(column: Column(name: "median_hfd",       contents: hfdValues))

    var measureTable = TableData()
    measureTable.dataFrame = df

    let processor = AutofocusCurveProcessor()
    var outputs: [String: ProcessData] = [
        "autofocus_result": TableData(),
        "fitted_curve":     TableData()
    ]

    try processor.execute(
        inputs: ["focus_measurements": measureTable],
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let valid = ((outputs["autofocus_result"] as? TableData)?.dataFrame?["valid"] as? AnyColumn)?[0] as? Bool
    #expect(valid == false, "Should be invalid for downward-opening parabola")
}

@Test("AutofocusCurveProcessor sigma-clips outliers")
func testAutofocusCurveSigmaClipping() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    // Perfect parabola with one extreme outlier
    let trueOptimal = 5000.0
    let positions = stride(from: 4600.0, through: 5400.0, by: 100.0).map { $0 }
    var hfdValues  = positions.map { 0.001 * ($0 - trueOptimal) * ($0 - trueOptimal) + 2.0 }
    // Insert outlier at position 4700 (index 1)
    hfdValues[1] = 50.0

    var df = DataFrame()
    df.append(column: Column(name: "focuser_position", contents: positions))
    df.append(column: Column(name: "median_hfd",       contents: hfdValues))

    var measureTable = TableData()
    measureTable.dataFrame = df

    let processor = AutofocusCurveProcessor()
    var outputs: [String: ProcessData] = [
        "autofocus_result": TableData(),
        "fitted_curve":     TableData()
    ]

    try processor.execute(
        inputs: ["focus_measurements": measureTable],
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let result = (outputs["autofocus_result"] as? TableData)?.dataFrame
    let valid   = (result?["valid"] as? AnyColumn)?[0] as? Bool
    let optimal = (result?["optimal_position"] as? AnyColumn)?[0] as? Double

    #expect(valid == true, "Should be valid after clipping the outlier")
    if let opt = optimal {
        #expect(abs(opt - trueOptimal) < 100.0, "Optimal position \(opt) should be near \(trueOptimal) after clipping")
    }
}

// MARK: - OpticalQualityProcessor Tests

/// Creates a synthetic 1024×1024 greyscale Metal texture for testing.
private func makeSyntheticTexture(width: Int = 1024, height: Int = 1024, device: MTLDevice) throws -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float,
        width: width,
        height: height,
        mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    guard let texture = device.makeTexture(descriptor: desc) else {
        throw ProcessorExecutionError.couldNotCreateResource("Cannot create synthetic texture")
    }
    // Fill with a uniform value (0.1) so it's non-empty
    var pixels = [Float](repeating: 0.1, count: width * height)
    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: &pixels,
        bytesPerRow: width * MemoryLayout<Float>.stride
    )
    return texture
}

/// Creates a synthetic Frame wrapping a texture.
private func makeSyntheticFrame(width: Int = 1024, height: Int = 1024, device: MTLDevice) throws -> Frame {
    let texture = try makeSyntheticTexture(width: width, height: height, device: device)
    var frame = Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)
    frame.texture = texture
    return frame
}

/// Builds a synthetic star DataFrame with a grid pattern and specified eccentricity / rotation_angle.
private func syntheticStarTable(
    imageWidth: Double = 1024, imageHeight: Double = 1024,
    gridN: Int = 5,
    eccentricity: Double = 0.6,
    rotationAngle: Double = 0.3,
    fwhmMajor: Double = 4.0,
    fwhmMinor: Double = 3.0
) -> DataFrame {
    var cxs: [Double] = [], cys: [Double] = [], eccs: [Double] = [],
        rots: [Double] = [], majs: [Double] = [], mins: [Double] = [],
        sats: [Bool] = [], ids: [Int] = [], areas: [Int] = [],
        majAxes: [Double] = [], minAxes: [Double] = [], fluxes: [Double] = []

    var id = 0
    for row in 0..<gridN {
        for col in 0..<gridN {
            let cx = (Double(col) + 0.5) / Double(gridN) * imageWidth
            let cy = (Double(row) + 0.5) / Double(gridN) * imageHeight
            cxs.append(cx); cys.append(cy)
            eccs.append(eccentricity); rots.append(rotationAngle)
            majs.append(fwhmMajor); mins.append(fwhmMinor)
            sats.append(false)
            ids.append(id); areas.append(20)
            majAxes.append(3.0); minAxes.append(2.0); fluxes.append(1000.0)
            id += 1
        }
    }

    var df = DataFrame()
    df.append(column: Column(name: "id",             contents: ids))
    df.append(column: Column(name: "area",           contents: areas))
    df.append(column: Column(name: "flux",           contents: fluxes))
    df.append(column: Column(name: "centroid_x",     contents: cxs))
    df.append(column: Column(name: "centroid_y",     contents: cys))
    df.append(column: Column(name: "major_axis",     contents: majAxes))
    df.append(column: Column(name: "minor_axis",     contents: minAxes))
    df.append(column: Column(name: "eccentricity",   contents: eccs))
    df.append(column: Column(name: "rotation_angle", contents: rots))
    df.append(column: Column(name: "fwhm_major",     contents: majs))
    df.append(column: Column(name: "fwhm_minor",     contents: mins))
    df.append(column: Column(name: "saturated",      contents: sats))
    return df
}

@Test("OpticalQualityProcessor diagnoses uniform eccentricity as sensor_tilt")
func testOpticalQualityTiltDiagnosis() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    let frame = try makeSyntheticFrame(device: device)
    var starTable = TableData()
    starTable.dataFrame = syntheticStarTable(eccentricity: 0.6, rotationAngle: 0.3)

    let processor = OpticalQualityProcessor()
    var outputs: [String: ProcessData] = [
        "optical_quality_map":     TableData(),
        "optical_quality_summary": TableData()
    ]

    try processor.execute(
        inputs: ["input_frame": frame, "pixel_coordinates": starTable],
        outputs: &outputs,
        parameters: ["min_stars_per_cell": .int(1)],
        device: device,
        commandQueue: commandQueue
    )

    let summary = (outputs["optical_quality_summary"] as? TableData)?.dataFrame
    #expect(summary != nil, "optical_quality_summary should be set")

    let diagnosis = (summary?["diagnosis"] as? AnyColumn)?[0] as? String
    let meanEcc   = (summary?["global_mean_eccentricity"] as? AnyColumn)?[0] as? Double

    #expect(meanEcc != nil && abs(meanEcc! - 0.6) < 0.05,
            "Global mean eccentricity should be ≈ 0.6, got \(meanEcc ?? -1)")
    // With uniform eccentricity and no radial variation, diagnosis should not be "coma"
    // or "backfocus"; it should be either "sensor_tilt" or "well_collimated"
    if let d = diagnosis {
        #expect(d == "sensor_tilt" || d == "well_collimated",
                "Diagnosis should be sensor_tilt or well_collimated, got '\(d)'")
    } else {
        Issue.record("diagnosis column not found")
    }
}

@Test("OpticalQualityProcessor produces correct per-cell star counts")
func testOpticalQualityPerCellCounts() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    let frame = try makeSyntheticFrame(device: device)
    // 25 stars in a 5×5 grid → each grid cell in a 5×4 output grid should have ≥1 star
    var starTable = TableData()
    starTable.dataFrame = syntheticStarTable(gridN: 5)

    let processor = OpticalQualityProcessor()
    var outputs: [String: ProcessData] = [
        "optical_quality_map":     TableData(),
        "optical_quality_summary": TableData()
    ]

    try processor.execute(
        inputs: ["input_frame": frame, "pixel_coordinates": starTable],
        outputs: &outputs,
        parameters: ["grid_cols": .int(5), "grid_rows": .int(5), "min_stars_per_cell": .int(1)],
        device: device,
        commandQueue: commandQueue
    )

    let mapDF = (outputs["optical_quality_map"] as? TableData)?.dataFrame
    #expect(mapDF?.rows.count == 25, "5×5 grid should produce 25 cell rows")

    // Each cell with at least 1 star should report that star count
    if let mapDF = mapDF,
       let countCol = mapDF.columns.first(where: { $0.name == "star_count" }) {
        let counts = (0..<mapDF.rows.count).compactMap { countCol[$0] as? Int }
        let totalStars = counts.reduce(0, +)
        // With 25 stars in a 5×5 grid over a 5×5 output grid, most cells should have ≥1
        #expect(totalStars >= 20, "At least 20 of 25 stars should be counted in cells")
    }
}

@Test("OpticalQualityProcessor handles empty star table")
func testOpticalQualityEmptyTable() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    let frame = try makeSyntheticFrame(device: device)

    var df = DataFrame()
    df.append(column: Column(name: "id",             contents: [] as [Int]))
    df.append(column: Column(name: "area",           contents: [] as [Int]))
    df.append(column: Column(name: "flux",           contents: [] as [Double]))
    df.append(column: Column(name: "centroid_x",     contents: [] as [Double]))
    df.append(column: Column(name: "centroid_y",     contents: [] as [Double]))
    df.append(column: Column(name: "major_axis",     contents: [] as [Double]))
    df.append(column: Column(name: "minor_axis",     contents: [] as [Double]))
    df.append(column: Column(name: "eccentricity",   contents: [] as [Double]))
    df.append(column: Column(name: "rotation_angle", contents: [] as [Double]))
    df.append(column: Column(name: "fwhm_major",     contents: [] as [Double]))
    df.append(column: Column(name: "fwhm_minor",     contents: [] as [Double]))
    df.append(column: Column(name: "saturated",      contents: [] as [Bool]))
    var starTable = TableData()
    starTable.dataFrame = df

    let processor = OpticalQualityProcessor()
    var outputs: [String: ProcessData] = [
        "optical_quality_map":     TableData(),
        "optical_quality_summary": TableData()
    ]

    // Should not throw — just produce an insufficient_data diagnosis
    try processor.execute(
        inputs: ["input_frame": frame, "pixel_coordinates": starTable],
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let diagnosis = ((outputs["optical_quality_summary"] as? TableData)?
        .dataFrame?["diagnosis"] as? AnyColumn)?[0] as? String
    #expect(diagnosis == "insufficient_data",
            "Empty star table should produce 'insufficient_data' diagnosis")
}

// MARK: - CollimationAnalysisProcessor Tests

@Test("CollimationAnalysisProcessor computes correct global offset from synthetic donuts")
func testCollimationAnalysisSyntheticOffset() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    let frame = try makeSyntheticFrame(device: device)

    // 6 donuts spread across the image, all with the same offset (3, -3)
    let knownOffX = 3.0, knownOffY = -3.0
    let positions: [(Double, Double)] = [
        (200, 200), (512, 200), (800, 200),
        (200, 800), (512, 800), (800, 800)
    ]

    var ids: [Int] = [], ocxs: [Double] = [], ocys: [Double] = [],
        ors: [Double] = [], ovs: [Int] = [],
        icxs: [Double] = [], icys: [Double] = [],
        irs: [Double] = [], ivs: [Int] = [],
        offXs: [Double] = [], offYs: [Double] = [],
        offMs: [Double] = [], offAs: [Double] = [], ratios: [Double] = []

    for (i, (cx, cy)) in positions.enumerated() {
        let outerR = 60.0, innerR = 22.0
        ids.append(i)
        ocxs.append(cx); ocys.append(cy)
        ors.append(outerR); ovs.append(80)
        icxs.append(cx + knownOffX); icys.append(cy + knownOffY)
        irs.append(innerR); ivs.append(60)
        offXs.append(knownOffX); offYs.append(knownOffY)
        offMs.append(sqrt(knownOffX * knownOffX + knownOffY * knownOffY))
        offAs.append(atan2(knownOffY, knownOffX))
        ratios.append(innerR / outerR)
    }

    var df = DataFrame()
    df.append(column: Column(name: "id",               contents: ids))
    df.append(column: Column(name: "outer_cx",         contents: ocxs))
    df.append(column: Column(name: "outer_cy",         contents: ocys))
    df.append(column: Column(name: "outer_r",          contents: ors))
    df.append(column: Column(name: "outer_votes",      contents: ovs))
    df.append(column: Column(name: "inner_cx",         contents: icxs))
    df.append(column: Column(name: "inner_cy",         contents: icys))
    df.append(column: Column(name: "inner_r",          contents: irs))
    df.append(column: Column(name: "inner_votes",      contents: ivs))
    df.append(column: Column(name: "offset_x",         contents: offXs))
    df.append(column: Column(name: "offset_y",         contents: offYs))
    df.append(column: Column(name: "offset_magnitude", contents: offMs))
    df.append(column: Column(name: "offset_angle",     contents: offAs))
    df.append(column: Column(name: "r_ratio",          contents: ratios))

    var donutTable = TableData()
    donutTable.dataFrame = df

    let processor = CollimationAnalysisProcessor()
    var outputs: [String: ProcessData] = [
        "collimation_map":     TableData(),
        "collimation_summary": TableData()
    ]

    try processor.execute(
        inputs: ["donuts": donutTable, "input_frame": frame],
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let summary = (outputs["collimation_summary"] as? TableData)?.dataFrame
    #expect(summary != nil, "collimation_summary should be produced")

    let totalDonuts = (summary?["total_donuts"] as? AnyColumn)?[0] as? Int
    let globalOffX  = (summary?["collimation_offset_x"] as? AnyColumn)?[0] as? Double
    let globalOffY  = (summary?["collimation_offset_y"] as? AnyColumn)?[0] as? Double
    let diagnosis   = (summary?["diagnosis"] as? AnyColumn)?[0] as? String

    #expect(totalDonuts == 6, "Should count 6 donuts")
    if let gox = globalOffX {
        #expect(abs(gox - knownOffX) < 0.01,
                "Global offset X should be ≈ \(knownOffX), got \(gox)")
    }
    if let goy = globalOffY {
        #expect(abs(goy - knownOffY) < 0.01,
                "Global offset Y should be ≈ \(knownOffY), got \(goy)")
    }
    // knownOffMag ≈ 4.24, which is >= 2 and < 5 → "needs_adjustment"
    #expect(diagnosis == "needs_adjustment",
            "Offset ~4.24px should be diagnosed as needs_adjustment, got '\(diagnosis ?? "")'")
}

@Test("CollimationAnalysisProcessor diagnoses well_collimated for zero offsets")
func testCollimationAnalysisWellCollimated() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    let frame = try makeSyntheticFrame(device: device)

    let positions: [(Double, Double)] = [
        (200, 200), (512, 300), (800, 200),
        (200, 800), (512, 700), (800, 800)
    ]

    var ids: [Int] = [], ocxs: [Double] = [], ocys: [Double] = [],
        ors: [Double] = [], ovs: [Int] = [],
        icxs: [Double] = [], icys: [Double] = [],
        irs: [Double] = [], ivs: [Int] = [],
        offXs: [Double] = [], offYs: [Double] = [],
        offMs: [Double] = [], offAs: [Double] = [], ratios: [Double] = []

    for (i, (cx, cy)) in positions.enumerated() {
        ids.append(i)
        ocxs.append(cx); ocys.append(cy)
        ors.append(60.0); ovs.append(80)
        icxs.append(cx); icys.append(cy)   // inner centre = outer centre → zero offset
        irs.append(22.0); ivs.append(60)
        offXs.append(0.0); offYs.append(0.0)
        offMs.append(0.0); offAs.append(0.0)
        ratios.append(22.0 / 60.0)
    }

    var df = DataFrame()
    df.append(column: Column(name: "id",               contents: ids))
    df.append(column: Column(name: "outer_cx",         contents: ocxs))
    df.append(column: Column(name: "outer_cy",         contents: ocys))
    df.append(column: Column(name: "outer_r",          contents: ors))
    df.append(column: Column(name: "outer_votes",      contents: ovs))
    df.append(column: Column(name: "inner_cx",         contents: icxs))
    df.append(column: Column(name: "inner_cy",         contents: icys))
    df.append(column: Column(name: "inner_r",          contents: irs))
    df.append(column: Column(name: "inner_votes",      contents: ivs))
    df.append(column: Column(name: "offset_x",         contents: offXs))
    df.append(column: Column(name: "offset_y",         contents: offYs))
    df.append(column: Column(name: "offset_magnitude", contents: offMs))
    df.append(column: Column(name: "offset_angle",     contents: offAs))
    df.append(column: Column(name: "r_ratio",          contents: ratios))

    var donutTable = TableData()
    donutTable.dataFrame = df

    let processor = CollimationAnalysisProcessor()
    var outputs: [String: ProcessData] = [
        "collimation_map":     TableData(),
        "collimation_summary": TableData()
    ]

    try processor.execute(
        inputs: ["donuts": donutTable, "input_frame": frame],
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let diagnosis = ((outputs["collimation_summary"] as? TableData)?
        .dataFrame?["diagnosis"] as? AnyColumn)?[0] as? String
    #expect(diagnosis == "well_collimated",
            "Zero offsets should be diagnosed as well_collimated, got '\(diagnosis ?? "")'")
}

// MARK: - HFDProcessor Tests (focused mode)

@Test("HFDProcessor computes reasonable HFD for a Gaussian star profile")
func testHFDProcessorFocusedMode() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    // Create a 128×128 texture with a 2D Gaussian centred at (64,64), sigma=4
    let W = 128, H = 128
    let sigma = 4.0, cx = 64.0, cy = 64.0
    var pixels = [Float](repeating: 0, count: W * H)
    for y in 0..<H {
        for x in 0..<W {
            let dx = Double(x) - cx, dy = Double(y) - cy
            let val = Float(exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma)))
            pixels[y * W + x] = val
        }
    }

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float, width: W, height: H, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    guard let texture = device.makeTexture(descriptor: desc) else {
        Issue.record("Cannot create texture"); return
    }
    texture.replace(
        region: MTLRegionMake2D(0, 0, W, H),
        mipmapLevel: 0,
        withBytes: &pixels,
        bytesPerRow: W * MemoryLayout<Float>.stride
    )

    var frame = Frame(type: .light, filter: .none, colorSpace: .greyscale, dataType: .float)
    frame.texture = texture

    // Star table with one star at (64,64), major/minor axis ≈ sigma*2
    var starDF = DataFrame()
    starDF.append(column: Column(name: "id",             contents: [0]))
    starDF.append(column: Column(name: "area",           contents: [50]))
    starDF.append(column: Column(name: "flux",           contents: [1.0]))
    starDF.append(column: Column(name: "centroid_x",     contents: [cx]))
    starDF.append(column: Column(name: "centroid_y",     contents: [cy]))
    starDF.append(column: Column(name: "major_axis",     contents: [sigma * 2.0]))
    starDF.append(column: Column(name: "minor_axis",     contents: [sigma * 2.0]))
    starDF.append(column: Column(name: "eccentricity",   contents: [0.0]))
    starDF.append(column: Column(name: "rotation_angle", contents: [0.0]))
    starDF.append(column: Column(name: "fwhm_major",     contents: [sigma * 2.355]))
    starDF.append(column: Column(name: "fwhm_minor",     contents: [sigma * 2.355]))
    starDF.append(column: Column(name: "saturated",      contents: [false]))
    var starTable = TableData()
    starTable.dataFrame = starDF

    let processor = HFDProcessor()
    var outputs: [String: ProcessData] = [
        "hfd_measurements": TableData(),
        "median_hfd":        TableData()
    ]

    try processor.execute(
        inputs: ["input_frame": frame, "pixel_coordinates": starTable],
        outputs: &outputs,
        parameters: ["region_multiplier": .double(6.0)],
        device: device,
        commandQueue: commandQueue
    )

    let hfdDF = (outputs["hfd_measurements"] as? TableData)?.dataFrame
    #expect(hfdDF?.rows.count == 1, "Should produce one HFD measurement row")

    let hfd = (hfdDF?["hfd"] as? AnyColumn)?[0] as? Double
    // Analytical HFD for a 2D Gaussian: HFD = 2σ√(π/ln2) ≈ 2 * 4 * 2.128 ≈ 17.02
    // In practice the finite-pixel approximation gives a value close to this.
    // We accept a wide tolerance of ±50% since the region may clip the wings.
    if let h = hfd {
        let expectedHFD = 2.0 * sigma * sqrt(.pi / log(2.0))
        #expect(h > expectedHFD * 0.5 && h < expectedHFD * 1.5,
                "HFD \(h) should be within 50% of expected ≈ \(String(format: "%.2f", expectedHFD))")
    } else {
        Issue.record("hfd column not found in output table")
    }
}

@Test("HFDProcessor outputs median_hfd table with mode column")
func testHFDProcessorMedianTable() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        Issue.record("Metal not available"); return
    }

    let frame = try makeSyntheticFrame(width: 256, height: 256, device: device)

    var starDF = DataFrame()
    starDF.append(column: Column(name: "id",             contents: [0, 1]))
    starDF.append(column: Column(name: "area",           contents: [20, 20]))
    starDF.append(column: Column(name: "flux",           contents: [500.0, 500.0]))
    starDF.append(column: Column(name: "centroid_x",     contents: [64.0, 192.0]))
    starDF.append(column: Column(name: "centroid_y",     contents: [64.0, 192.0]))
    starDF.append(column: Column(name: "major_axis",     contents: [4.0, 4.0]))
    starDF.append(column: Column(name: "minor_axis",     contents: [4.0, 4.0]))
    starDF.append(column: Column(name: "eccentricity",   contents: [0.0, 0.0]))
    starDF.append(column: Column(name: "rotation_angle", contents: [0.0, 0.0]))
    starDF.append(column: Column(name: "fwhm_major",     contents: [9.4, 9.4]))
    starDF.append(column: Column(name: "fwhm_minor",     contents: [9.4, 9.4]))
    starDF.append(column: Column(name: "saturated",      contents: [false, false]))
    var starTable = TableData()
    starTable.dataFrame = starDF

    let processor = HFDProcessor()
    var outputs: [String: ProcessData] = [
        "hfd_measurements": TableData(),
        "median_hfd":       TableData()
    ]

    try processor.execute(
        inputs: ["input_frame": frame, "pixel_coordinates": starTable],
        outputs: &outputs,
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let medianDF = (outputs["median_hfd"] as? TableData)?.dataFrame
    #expect(medianDF?.rows.count == 1, "median_hfd table should have one row")

    let mode = (medianDF?["mode"] as? AnyColumn)?[0] as? String
    #expect(mode == "focused", "Mode should be 'focused' when pixel_coordinates input is used")
}
