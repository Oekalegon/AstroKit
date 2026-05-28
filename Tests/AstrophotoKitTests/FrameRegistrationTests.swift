import Testing
import Foundation
import Metal
import TabularData
@testable import AstrophotoKit

// MARK: - RegistrationCore — pure math (no Metal, no FITS)

@Test("median handles empty, odd, and even-length arrays")
func testMedian() {
    #expect(RegistrationCore.median([]) == 0)
    #expect(RegistrationCore.median([7.0]) == 7.0)
    #expect(RegistrationCore.median([1.0, 2.0, 3.0]) == 2.0)
    #expect(RegistrationCore.median([1.0, 2.0, 3.0, 4.0]) == 2.5)
    #expect(RegistrationCore.median([3.0, 1.0, 2.0]) == 2.0)  // unsorted input
}

@Test("leastSquaresSimilarity recovers identity transform")
func testLeastSquaresIdentity() {
    let pts: [StarPoint] = [.init(x: 0, y: 0), .init(x: 200, y: 0),
                             .init(x: 100, y: 150), .init(x: 0, y: 200)]
    let pairs = pts.map { (ref: $0, tgt: $0) }
    let (t, rmse) = RegistrationCore.leastSquaresSimilarity(pairs: pairs)
    #expect(abs(t.tx)        < 1e-6)
    #expect(abs(t.ty)        < 1e-6)
    #expect(abs(t.rotation)  < 1e-6)
    #expect(abs(t.scale - 1) < 1e-6)
    #expect(rmse             < 1e-9)
}

@Test("leastSquaresSimilarity recovers pure translation")
func testLeastSquaresTranslation() {
    let tx = 47.0, ty = -23.0
    let pts: [StarPoint] = [.init(x: 0, y: 0), .init(x: 300, y: 0),
                             .init(x: 150, y: 200), .init(x: 0, y: 300)]
    let pairs = pts.map { ref -> (ref: StarPoint, tgt: StarPoint) in
        (ref, .init(x: ref.x + tx, y: ref.y + ty))
    }
    let (t, rmse) = RegistrationCore.leastSquaresSimilarity(pairs: pairs)
    #expect(abs(t.tx - tx)      < 1e-6)
    #expect(abs(t.ty - ty)      < 1e-6)
    #expect(abs(t.rotation)     < 1e-6)
    #expect(abs(t.scale - 1.0)  < 1e-6)
    #expect(rmse                < 1e-9)
}

@Test("leastSquaresSimilarity recovers rotation and scale")
func testLeastSquaresRotationAndScale() {
    let rotation = Double.pi / 8  // 22.5°
    let scale    = 0.95
    let T = SimilarityTransform(tx: 30, ty: -15, rotation: rotation, scale: scale)
    let pts: [StarPoint] = [.init(x: 0, y: 0), .init(x: 400, y: 0),
                             .init(x: 200, y: 250), .init(x: 0, y: 400),
                             .init(x: 400, y: 400)]
    let pairs = pts.map { ref -> (ref: StarPoint, tgt: StarPoint) in
        (ref, .init(x: T.a * ref.x - T.b * ref.y + T.tx,
                    y: T.b * ref.x + T.a * ref.y + T.ty))
    }
    let (t, rmse) = RegistrationCore.leastSquaresSimilarity(pairs: pairs)
    #expect(abs(t.tx - T.tx)             < 1e-6)
    #expect(abs(t.ty - T.ty)             < 1e-6)
    #expect(abs(t.rotation - T.rotation) < 1e-6)
    #expect(abs(t.scale - T.scale)       < 1e-6)
    #expect(rmse                         < 1e-9)
}

@Test("leastSquaresSimilarity returns identity for fewer than 2 pairs")
func testLeastSquaresTooFewPairs() {
    let (t, _) = RegistrationCore.leastSquaresSimilarity(pairs: [])
    #expect(t.tx == 0 && t.ty == 0 && t.rotation == 0 && t.scale == 1)

    let single: [(ref: StarPoint, tgt: StarPoint)] = [(.init(x: 10, y: 20), .init(x: 30, y: 40))]
    let (t2, _) = RegistrationCore.leastSquaresSimilarity(pairs: single)
    #expect(t2.tx == 0 && t2.ty == 0)
}

@Test("RANSAC recovers transform and rejects outliers")
func testRansacRejectsOutliers() {
    // 12 inlier pairs — exact translation (50, 30)
    var pairs: [(ref: StarPoint, tgt: StarPoint)] = (0..<12).map { i in
        let ref = StarPoint(x: Double(i % 4) * 100 + 50, y: Double(i / 4) * 100 + 50)
        return (ref, StarPoint(x: ref.x + 50, y: ref.y + 30))
    }
    // 4 outlier pairs — grossly different transform
    pairs += (0..<4).map { i in
        let ref = StarPoint(x: Double(i) * 120 + 700, y: Double(i) * 80 + 500)
        return (ref, StarPoint(x: ref.x + 300, y: ref.y - 200))
    }

    let (inliers, transform) = RegistrationCore.ransac(
        pairs: pairs, iterations: 500,
        inlierThreshold: 3.0, maxScaleDeviation: 0.1
    )

    #expect(inliers.count >= 10, "Should recover at least 10 of 12 inliers")
    #expect(abs(transform.tx - 50) < 2.0)
    #expect(abs(transform.ty - 30) < 2.0)
    #expect(abs(transform.scale - 1.0) < 0.05)
}

@Test("RANSAC returns empty inliers when all candidates violate scale constraint")
func testRansacScaleConstraint() {
    // All pairs encode a 3× scale, far outside maxScaleDeviation = 0.05
    let pairs: [(ref: StarPoint, tgt: StarPoint)] = (0..<8).map { i in
        let ref = StarPoint(x: Double(i) * 60 + 10, y: Double(i % 3) * 60 + 10)
        return (ref, StarPoint(x: ref.x * 3, y: ref.y * 3))
    }
    let (inliers, _) = RegistrationCore.ransac(
        pairs: pairs, iterations: 100,
        inlierThreshold: 3.0, maxScaleDeviation: 0.05
    )
    // RANSAC finds no valid candidate — bestInliers stays empty
    #expect(inliers.isEmpty, "No inliers expected when all pairs have a bad scale")
}

@Test("chooseBestFrame picks frame with most stars and sharpest FWHM")
func testChooseBestFrame() {
    let frames = [
        FrameStats(starCount: 50, meanFWHM: 3.0, medianFWHM: 3.0, meanEccentricity: 0,
                   meanPositionAngle: 0, meanFlux: 100, skyBackground: 200, skyNoise: 10),
        FrameStats(starCount: 80, meanFWHM: 2.5, medianFWHM: 2.5, meanEccentricity: 0,
                   meanPositionAngle: 0, meanFlux: 120, skyBackground: 200, skyNoise: 10),
        FrameStats(starCount: 80, meanFWHM: 5.0, medianFWHM: 5.0, meanEccentricity: 0,
                   meanPositionAngle: 0, meanFlux: 90,  skyBackground: 200, skyNoise: 10),
    ]
    // Frame 1: score = 80 - 2.5/10 = 79.75  (best)
    // Frame 0: score = 50 - 3.0/10 = 49.7
    // Frame 2: score = 80 - 5.0/10 = 79.5
    #expect(RegistrationCore.chooseBestFrame(frames) == 1)
}

@Test("chooseBestFrame on single frame returns 0")
func testChooseBestFrameSingle() {
    let frames = [FrameStats(starCount: 10, meanFWHM: 4.0, medianFWHM: 4.0,
                             meanEccentricity: 0, meanPositionAngle: 0,
                             meanFlux: 50, skyBackground: 100, skyNoise: 5)]
    #expect(RegistrationCore.chooseBestFrame(frames) == 0)
}

@Test("filterStarsByFWHM removes extended sources above ratio × median FWHM")
func testFilterStarsByFWHM() throws {
    // 4 normal stars (FWHM avg ≈ 3.0) + 1 extended source (FWHM avg ≈ 14.5)
    var df = DataFrame()
    df.append(column: Column<Int>   (name: "id",         contents: [1,   2,   3,   4,   5  ]))
    df.append(column: Column<Int>   (name: "area",       contents: [10,  11,  10,  12,  80 ]))
    df.append(column: Column<Double>(name: "flux",       contents: [100, 110, 105, 115, 500]))
    df.append(column: Column<Double>(name: "centroid_x", contents: [100, 200, 300, 400, 250]))
    df.append(column: Column<Double>(name: "centroid_y", contents: [100, 150, 200, 250, 300]))
    df.append(column: Column<Double>(name: "fwhm_major", contents: [3.1, 2.9, 3.0, 3.2, 15.0]))
    df.append(column: Column<Double>(name: "fwhm_minor", contents: [2.9, 2.8, 3.0, 3.1, 14.0]))
    var table = TableData()
    table.dataFrame = df

    // median avg FWHM ≈ 3.0; threshold = 2.5 × 3.0 = 7.5; extended source (14.5) is removed
    let filtered = RegistrationCore.filterStarsByFWHM(table, maxFWHMRatio: 2.5)
    #expect(filtered.dataFrame?.rows.count == 4, "Extended source should be filtered out")

    // High ratio: all 5 pass
    let unfiltered = RegistrationCore.filterStarsByFWHM(table, maxFWHMRatio: 6.0)
    #expect(unfiltered.dataFrame?.rows.count == 5, "All stars should pass with a generous ratio")
}

@Test("filterStarsByFWHM is a no-op on an empty table")
func testFilterStarsByFWHMEmpty() {
    let empty = TableData()
    let result = RegistrationCore.filterStarsByFWHM(empty, maxFWHMRatio: 2.5)
    #expect(result.dataFrame == nil)
}

// MARK: - Metal matching — agreement between GPU and CPU

@Test("metalMatch2D GPU results agree with CPU for distinct synthetic descriptors")
func testMetalMatch2DAgreesWithCPU() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { Issue.record("Metal not available"); return }

    // 15 well-separated descriptors so each descriptor has an unambiguous best match
    let n = 15
    let refDesc: [(Float, Float)] = (0..<n).map { i in (Float(i) * 0.06, Float(i) * 0.04) }
    let tgtDesc: [(Float, Float)] = refDesc  // identical → zero-distance perfect matches

    guard let gpu = RegistrationCore.metalMatch2D(
        refDesc: refDesc, tgtDesc: tgtDesc, device: device, commandQueue: commandQueue
    ) else { Issue.record("metalMatch2D returned nil"); return }

    // CPU reference
    var cpuFwdIdx  = [Int32](repeating: -1,       count: n)
    var cpuFwdBest = [Float](repeating: .infinity, count: n)
    var cpuFwdSec  = [Float](repeating: .infinity, count: n)
    var cpuBwdIdx  = [Int32](repeating: -1,       count: n)
    var cpuBwdBest = [Float](repeating: .infinity, count: n)
    for (ti, tq) in tgtDesc.enumerated() {
        for (ri, rq) in refDesc.enumerated() {
            let d1 = tq.0 - rq.0, d2 = tq.1 - rq.1
            let d  = (d1*d1 + d2*d2).squareRoot()
            if d < cpuFwdBest[ti] { cpuFwdSec[ti] = cpuFwdBest[ti]; cpuFwdBest[ti] = d; cpuFwdIdx[ti] = Int32(ri) }
            else if d < cpuFwdSec[ti] { cpuFwdSec[ti] = d }
            if d < cpuBwdBest[ri]    { cpuBwdBest[ri] = d; cpuBwdIdx[ri] = Int32(ti) }
        }
    }

    for i in 0..<n {
        #expect(gpu.fwdBestIdx[i]  == cpuFwdIdx[i],  "fwdBestIdx[\(i)]")
        #expect(gpu.bwdBestIdx[i]  == cpuBwdIdx[i],  "bwdBestIdx[\(i)]")
        #expect(abs(gpu.fwdBestDist[i] - cpuFwdBest[i]) < 1e-5, "fwdBestDist[\(i)]")
        #expect(abs(gpu.fwdSecDist[i]  - cpuFwdSec[i])  < 1e-5, "fwdSecDist[\(i)]")
    }
}

@Test("metalMatch2D finds all mutual matches when ref == tgt")
func testMetalMatch2DPerfectMatchSet() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { Issue.record("Metal not available"); return }

    let n = 10
    let desc: [(Float, Float)] = (0..<n).map { i in (Float(i) * 0.07, Float(i) * 0.05) }
    guard let gpu = RegistrationCore.metalMatch2D(
        refDesc: desc, tgtDesc: desc, device: device, commandQueue: commandQueue
    ) else { Issue.record("metalMatch2D returned nil"); return }

    // With identical ref and tgt, every descriptor should match itself
    for i in 0..<n {
        #expect(gpu.fwdBestIdx[i]  == Int32(i), "Each descriptor should match itself (fwd)")
        #expect(gpu.bwdBestIdx[i]  == Int32(i), "Each descriptor should match itself (bwd)")
        #expect(gpu.fwdBestDist[i] < 1e-6,      "Distance to self should be zero")
    }
}

@Test("metalMatch4D GPU results agree with CPU for distinct synthetic descriptors")
func testMetalMatch4DAgreesWithCPU() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { Issue.record("Metal not available"); return }

    let n = 12
    var refDesc: [(Float, Float, Float, Float)] = []
    for i in 0..<n {
        let f = Float(i)
        refDesc.append((f * 0.06, f * 0.04, f * 0.05, f * 0.03))
    }
    let tgtDesc = refDesc

    guard let gpu = RegistrationCore.metalMatch4D(
        refDesc: refDesc, tgtDesc: tgtDesc, device: device, commandQueue: commandQueue
    ) else { Issue.record("metalMatch4D returned nil"); return }

    var cpuFwdIdx  = [Int32](repeating: -1,       count: n)
    var cpuFwdBest = [Float](repeating: .infinity, count: n)
    var cpuFwdSec  = [Float](repeating: .infinity, count: n)
    var cpuBwdIdx  = [Int32](repeating: -1,       count: n)
    var cpuBwdBest = [Float](repeating: .infinity, count: n)
    for (ti, tq) in tgtDesc.enumerated() {
        for (ri, rq) in refDesc.enumerated() {
            let d1 = tq.0-rq.0, d2 = tq.1-rq.1, d3 = tq.2-rq.2, d4 = tq.3-rq.3
            let d  = (d1*d1 + d2*d2 + d3*d3 + d4*d4).squareRoot()
            if d < cpuFwdBest[ti] { cpuFwdSec[ti] = cpuFwdBest[ti]; cpuFwdBest[ti] = d; cpuFwdIdx[ti] = Int32(ri) }
            else if d < cpuFwdSec[ti] { cpuFwdSec[ti] = d }
            if d < cpuBwdBest[ri]    { cpuBwdBest[ri] = d; cpuBwdIdx[ri] = Int32(ti) }
        }
    }

    for i in 0..<n {
        #expect(gpu.fwdBestIdx[i] == cpuFwdIdx[i], "fwdBestIdx[\(i)]")
        #expect(gpu.bwdBestIdx[i] == cpuBwdIdx[i], "bwdBestIdx[\(i)]")
        #expect(abs(gpu.fwdBestDist[i] - cpuFwdBest[i]) < 1e-5, "fwdBestDist[\(i)]")
    }
}

// MARK: - Pipeline integration tests (require Metal + FITS files)

/// Loads three same-field luminance FITS frames from the test bundle.
private func loadLuminanceFrames(device: MTLDevice) throws -> [Frame]? {
    let names = [
        "CHI-1-CMOS_2025-03-25T08-25-40_LDN43TheCosmicBatNebula_Luminance_300s_ID493996_cal",
        "CHI-1-CMOS_2025-03-25T08-32-00_LDN43TheCosmicBatNebula_Luminance_300s_ID493997_cal",
        "CHI-1-CMOS_2025-03-25T08-37-11_LDN43TheCosmicBatNebula_Luminance_300s_ID493998_cal",
    ]
    var frames: [Frame] = []
    for name in names {
        var url: URL?
        if let u = Bundle.module.url(forResource: name, withExtension: "fits") { url = u }
        if url == nil {
            for b in Bundle.allBundles {
                if let u = b.url(forResource: name, withExtension: "fits") { url = u; break }
            }
        }
        guard let resolved = url else { return nil }
        let fitsFile  = try FITSFile(path: resolved.path)
        let fitsImage = try fitsFile.readFITSImage()
        frames.append(try Frame(fitsImage: fitsImage, device: device))
    }
    return frames
}

@Test("frame_registration pipeline registers real luminance frames")
func testFrameRegistrationPipelineRegistersLuminanceFrames() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { Issue.record("Metal not available"); return }

    guard let frames = try loadLuminanceFrames(device: device) else { return } // skip if no test FITS
    guard let pipelineURL = getPipelineResourceURL(name: "frame-registration") else { return }

    let pipeline  = try Pipeline.load(from: pipelineURL)
    let runner    = PipelineRunner(pipeline: pipeline)
    let frameSet  = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])

    let outputs = try await runner.execute(
        inputs: ["input_frames": frameSet],
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let regData = outputs.first { data in
        if case .output(_, _, _, let sid) = data.outputLink { return sid == "registration.registration_table" }
        return false
    }
    guard let table = regData as? TableData, let df = table.dataFrame else {
        Issue.record("registration_table not produced"); return
    }

    #expect(df.rows.count == 3, "One row per input frame")
    for row in df.rows {
        let success = (row["registration_success"] as? Int32) ?? 0
        #expect(success == 1, "Every frame should register successfully")
        let scale = (row["scale"] as? Double) ?? 0
        #expect(abs(scale - 1.0) < 0.1, "Scale should be ~1.0 for same equipment")
        let rotDeg = (row["rotation_deg"] as? Double) ?? 999
        #expect(abs(rotDeg) < 5.0, "Rotation should be small for a guided sequence")
    }
}

@Test("frame_registration_triangle pipeline registers real luminance frames")
func testFrameRegistrationTrianglePipelineRegistersLuminanceFrames() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { Issue.record("Metal not available"); return }

    guard let frames = try loadLuminanceFrames(device: device) else { return }
    guard let pipelineURL = getPipelineResourceURL(name: "frame-registration-triangle") else { return }

    let pipeline  = try Pipeline.load(from: pipelineURL)
    let runner    = PipelineRunner(pipeline: pipeline)
    let frameSet  = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])

    let outputs = try await runner.execute(
        inputs: ["input_frames": frameSet],
        parameters: [:],
        device: device,
        commandQueue: commandQueue
    )

    let regData = outputs.first { data in
        if case .output(_, _, _, let sid) = data.outputLink { return sid == "registration.registration_table" }
        return false
    }
    guard let table = regData as? TableData, let df = table.dataFrame else {
        Issue.record("registration_table not produced"); return
    }

    #expect(df.rows.count == 3)
    for row in df.rows {
        let success = (row["registration_success"] as? Int32) ?? 0
        #expect(success == 1, "Every frame should register successfully")
        let scale = (row["scale"] as? Double) ?? 0
        #expect(abs(scale - 1.0) < 0.1)
    }
}

@Test("quad and triangle pipelines produce consistent transforms for the same frames")
func testQuadAndTriangleProduceConsistentTransforms() async throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { Issue.record("Metal not available"); return }

    guard let frames = try loadLuminanceFrames(device: device) else { return }
    guard let quadURL     = getPipelineResourceURL(name: "frame-registration"),
          let triangleURL = getPipelineResourceURL(name: "frame-registration-triangle")
    else { return }

    let frameSet = FrameSet(frames: frames, outputProcess: nil, inputProcesses: [])

    func runAndExtract(url: URL) async throws -> [(tx: Double, ty: Double, scale: Double)]? {
        let runner  = PipelineRunner(pipeline: try Pipeline.load(from: url))
        let outputs = try await runner.execute(
            inputs: ["input_frames": frameSet],
            parameters: [:], device: device, commandQueue: commandQueue
        )
        guard let table = outputs.first(where: { data in
            if case .output(_, _, _, let sid) = data.outputLink { return sid == "registration.registration_table" }
            return false
        }) as? TableData, let df = table.dataFrame else { return nil }
        return df.rows.map { row in
            (tx:    (row["translation_x"] as? Double) ?? 0,
             ty:    (row["translation_y"] as? Double) ?? 0,
             scale: (row["scale"]         as? Double) ?? 1)
        }
    }

    guard let quadResults     = try await runAndExtract(url: quadURL),
          let triangleResults = try await runAndExtract(url: triangleURL)
    else { Issue.record("Could not extract results"); return }

    #expect(quadResults.count == triangleResults.count)
    for (q, t) in zip(quadResults, triangleResults) {
        // Both algorithms should agree within 2 pixels on translation
        #expect(abs(q.tx - t.tx) < 2.0, "tx should agree: quad=\(q.tx) triangle=\(t.tx)")
        #expect(abs(q.ty - t.ty) < 2.0, "ty should agree: quad=\(q.ty) triangle=\(t.ty)")
        #expect(abs(q.scale - t.scale) < 0.02, "scale should agree")
    }
}
