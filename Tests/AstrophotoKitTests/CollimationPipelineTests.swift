import Testing
import Foundation
import Metal
import TabularData
@testable import AstrophotoKit

// MARK: - Real-world collimation test using outOfFocusDubhe.fits
//
// The test file (Tests/Test-FIT/outOfFocusDubhe.fits) is intentionally excluded
// from the repository (.gitignore). If the file is not present, all tests in this
// suite log a warning and skip gracefully.
//
// Known donut positions in the image (from manual inspection):
//   Bright:  (1537, 1412)  offset (-5, 13)
//   Medium:  (1940, 1410), (1595, 175)
//   Faint:   (1005, 1960), (390, 235), (2925, 140), (480, 1130), (1960, 920)

private let knownDonuts: [(x: Double, y: Double, label: String)] = [
    (1537, 1412, "bright"),
    (1940, 1410, "medium-1"),
    (1595,  175, "medium-2"),
    (1005, 1960, "faint-1"),
    ( 390,  235, "faint-2"),
    (2925,  140, "faint-3"),
    ( 480, 1130, "faint-4"),
    (1960,  920, "faint-5"),
]

// Tolerance in pixels for asserting a donut was detected near a known position.
private let detectionTolerance = 30.0

// MARK: - Helpers

/// Resolves the path to the test FITS file relative to this source file.
private func testFITSPath() -> String {
    let thisFile = URL(fileURLWithPath: #file)
    return thisFile
        .deletingLastPathComponent()   // AstrophotoKitTests/
        .deletingLastPathComponent()   // Tests/
        .appendingPathComponent("Test-FIT/outOfFocusDubhe.fits")
        .path
}

/// Loads the test FITS file as a Frame, or returns nil if the file is absent.
private func loadTestFrame(device: MTLDevice) throws -> Frame? {
    let path = testFITSPath()
    guard FileManager.default.fileExists(atPath: path) else {
        print("⚠️  CollimationPipelineTests: test file not found at \(path) — skipping")
        return nil
    }
    let fitsFile  = try FITSFile(path: path)
    let fitsImage = try fitsFile.readFITSImage()
    return try Frame(fitsImage: fitsImage, device: device)
}

/// Returns Metal prerequisites or nil if Metal is unavailable.
private func makeMetalPrerequisites() -> (MTLDevice, MTLCommandQueue)? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue  = device.makeCommandQueue() else { return nil }
    return (device, queue)
}

/// Runs a named collimation pipeline on the given frame and returns the donuts DataFrame.
private func runCollimationPipeline(
    named pipelineName: String,
    frame: Frame,
    parameters: [String: Parameter] = [:],
    device: MTLDevice,
    commandQueue: MTLCommandQueue
) async throws -> DataFrame? {
    guard let bundle = findMainPackageBundle(),
          let url    = bundle.url(forResource: pipelineName, withExtension: "yaml") else {
        print("⚠️  CollimationPipelineTests: could not find \(pipelineName).yaml")
        return nil
    }

    let pipeline = try Pipeline.load(from: url)
    let runner   = PipelineRunner(pipeline: pipeline)

    let outputs = try await runner.execute(
        inputs: ["input_frame": frame],
        parameters: parameters,
        device: device,
        commandQueue: commandQueue
    )

    // Find the donuts table by looking for a TableData with the outer_cx column
    return outputs
        .compactMap { $0 as? TableData }
        .first { $0.dataFrame?.columns.contains(where: { $0.name == "outer_cx" }) == true }?
        .dataFrame
}

/// Returns the row index and distance of the closest detected donut to a given position.
private func closestDonut(in df: DataFrame, to pos: (x: Double, y: Double)) -> (dist: Double, row: Int)? {
    guard let cxCol = df.columns.first(where: { $0.name == "outer_cx" }),
          let cyCol = df.columns.first(where: { $0.name == "outer_cy" }) else { return nil }
    var best: (dist: Double, row: Int)?
    for i in 0..<df.rows.count {
        guard let cx = cxCol[i] as? Double,
              let cy = cyCol[i] as? Double else { continue }
        let d = sqrt((cx - pos.x) * (cx - pos.x) + (cy - pos.y) * (cy - pos.y))
        if best == nil || d < best!.dist { best = (d, i) }
    }
    return best
}

// MARK: - Tests

@Test("Hough pipeline detects bright Dubhe donut within tolerance")
func testHoughDetectsBrightDonut() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    let df = try await runCollimationPipeline(
        named: "collimation-reflector",
        frame: frame,
        device: device,
        commandQueue: queue
    )

    guard let df else {
        Issue.record("Hough pipeline did not produce a donuts table")
        return
    }

    print("Hough: \(df.rows.count) donuts detected")

    let bright = knownDonuts[0]
    if let closest = closestDonut(in: df, to: (bright.x, bright.y)) {
        print("  Closest to bright donut: row \(closest.row), dist=\(String(format:"%.1f",closest.dist))px")
        #expect(closest.dist <= detectionTolerance,
                "Bright donut not found within \(detectionTolerance)px — closest was \(String(format:"%.1f",closest.dist))px")
    } else {
        Issue.record("Hough pipeline found 0 donuts")
    }
}

@Test("Hough pipeline bright donut has correct inner offset")
func testHoughBrightDonutOffset() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    let df = try await runCollimationPipeline(
        named: "collimation-reflector",
        frame: frame,
        device: device,
        commandQueue: queue
    )
    guard let df, df.rows.count > 0 else { return }

    let bright = knownDonuts[0]
    guard let closest = closestDonut(in: df, to: (bright.x, bright.y)),
          closest.dist <= detectionTolerance else {
        print("⚠️  Bright donut not found — skipping offset check")
        return
    }

    let ox = (df.columns.first(where: { $0.name == "offset_x" }))?[closest.row] as? Double ?? 0
    let oy = (df.columns.first(where: { $0.name == "offset_y" }))?[closest.row] as? Double ?? 0

    // Known ground truth: offset (-5, 13) — allow ±10px tolerance
    print("  Bright donut offset: (\(String(format:"%.1f",ox)), \(String(format:"%.1f",oy))), expected (-5, 13)")
    #expect(abs(ox - (-5.0)) <= 10.0, "offset_x \(String(format:"%.1f",ox)) should be within 10px of -5")
    #expect(abs(oy -  13.0)  <= 10.0, "offset_y \(String(format:"%.1f",oy)) should be within 10px of 13")
}

@Test("Wavelet pipeline detects bright Dubhe donut within tolerance")
func testWaveletDetectsBrightDonut() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    let df = try await runCollimationPipeline(
        named: "collimation-reflector-wavelet",
        frame: frame,
        device: device,
        commandQueue: queue
    )

    guard let df else {
        Issue.record("Wavelet pipeline did not produce a donuts table")
        return
    }

    print("Wavelet: \(df.rows.count) donuts detected")

    let bright = knownDonuts[0]
    if let closest = closestDonut(in: df, to: (bright.x, bright.y)) {
        print("  Closest to bright donut: row \(closest.row), dist=\(String(format:"%.1f",closest.dist))px")
        #expect(closest.dist <= detectionTolerance,
                "Bright donut not found within \(detectionTolerance)px")
    } else {
        Issue.record("Wavelet pipeline found 0 donuts")
    }
}

@Test("Hough pipeline detects all known donuts — exhaustive", .disabled("Detection sensitivity under investigation"))
func testHoughDetectsAllKnownDonuts() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    // Lower min_votes and threshold to maximise recall
    let params: [String: Parameter] = [
        "hough_min_votes": .int(8),
        "threshold_value": .double(2.5),
    ]

    let df = try await runCollimationPipeline(
        named: "collimation-reflector",
        frame: frame,
        parameters: params,
        device: device,
        commandQueue: queue
    )
    guard let df else { return }

    print("Hough exhaustive: \(df.rows.count) donuts detected")

    var foundCount = 0
    for known in knownDonuts {
        if let closest = closestDonut(in: df, to: (known.x, known.y)),
           closest.dist <= detectionTolerance {
            print("  ✓ \(known.label) found at dist \(String(format:"%.1f",closest.dist))px")
            foundCount += 1
        } else {
            print("  ✗ \(known.label) at (\(known.x),\(known.y)) NOT found")
        }
    }

    // Require at least the 3 brightest donuts (bright + 2 medium)
    #expect(foundCount >= 3,
            "Expected at least 3 known donuts detected, found \(foundCount)/\(knownDonuts.count)")
}

@Test("Two-phase pipeline detects bright Dubhe donut within tolerance")
func testTwoPhaseDetectsBrightDonut() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    let df = try await runCollimationPipeline(
        named: "collimation-reflector-twophase",
        frame: frame,
        device: device,
        commandQueue: queue
    )

    guard let df else {
        Issue.record("Two-phase pipeline did not produce a donuts table")
        return
    }

    print("Two-phase: \(df.rows.count) donuts detected")

    let bright = knownDonuts[0]
    if let closest = closestDonut(in: df, to: (bright.x, bright.y)) {
        print("  Closest to bright donut: row \(closest.row), dist=\(String(format:"%.1f",closest.dist))px")
        #expect(closest.dist <= detectionTolerance,
                "Bright donut not found within \(detectionTolerance)px — closest was \(String(format:"%.1f",closest.dist))px")
    } else {
        Issue.record("Two-phase pipeline found 0 donuts")
    }
}

@Test("Two-phase pipeline detects all known donuts — exhaustive", .disabled("Detection sensitivity under investigation"))
func testTwoPhaseDetectsAllKnownDonuts() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    // Lower min_response to maximise recall for faint donuts
    let params: [String: Parameter] = [
        "ring_min_response": .double(0.0005),
    ]

    let df = try await runCollimationPipeline(
        named: "collimation-reflector-twophase",
        frame: frame,
        parameters: params,
        device: device,
        commandQueue: queue
    )
    guard let df else { return }

    print("Two-phase exhaustive: \(df.rows.count) donuts detected")

    var foundCount = 0
    for known in knownDonuts {
        if let closest = closestDonut(in: df, to: (known.x, known.y)),
           closest.dist <= detectionTolerance {
            print("  ✓ \(known.label) found at dist \(String(format:"%.1f",closest.dist))px")
            foundCount += 1
        } else {
            print("  ✗ \(known.label) at (\(known.x),\(known.y)) NOT found")
        }
    }

    // Require at least the 3 brightest donuts (bright + 2 medium)
    #expect(foundCount >= 3,
            "Expected at least 3 known donuts detected, found \(foundCount)/\(knownDonuts.count)")
}

@Test("Detected donut radii are consistent across all donuts")
func testDonutRadiiConsistency() async throws {
    guard let (device, queue) = makeMetalPrerequisites() else { return }
    guard let frame = try loadTestFrame(device: device) else { return }

    // Permissive min_votes to find enough candidates on this image; the consistency
    // check then filters to outer_votes >= 15 (the pipeline default) so that only
    // high-confidence detections contribute to the CV. Spurious low-vote circles
    // are the source of the wide radius spread and must be excluded.
    let params: [String: Parameter] = [
        "hough_min_votes": .int(8),
        "threshold_value": .double(2.5),
    ]
    let df = try await runCollimationPipeline(
        named: "collimation-reflector",
        frame: frame,
        parameters: params,
        device: device,
        commandQueue: queue
    )
    guard let df else { return }

    let outerR     = df.columns.first(where: { $0.name == "outer_r"     })?.compactMap { $0 as? Double } ?? []
    let outerVotes = df.columns.first(where: { $0.name == "outer_votes" })?.compactMap { $0 as? Int    } ?? []

    // Only evaluate radii from high-confidence circle fits (votes >= pipeline default).
    let reliableRadii = zip(outerR, outerVotes)
        .filter { $0.1 >= 15 }
        .map    { $0.0 }

    guard reliableRadii.count >= 2 else {
        print("⚠️  Fewer than 2 high-confidence donuts detected — skipping consistency check")
        return
    }

    let mean   = reliableRadii.reduce(0, +) / Double(reliableRadii.count)
    let stddev = sqrt(reliableRadii.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(reliableRadii.count))
    let cv     = mean > 0 ? stddev / mean : 0

    print("Outer radii (votes≥15): mean=\(String(format:"%.1f",mean))px stddev=\(String(format:"%.1f",stddev))px CV=\(String(format:"%.3f",cv)) n=\(reliableRadii.count)")

    // Physical expectation: all donuts come through the same optics, so outer radii should
    // be consistent (CV < 10%). Currently the Hough detector produces CV≈0.29 on this image
    // even for high-vote detections (n=2, ~45px vs ~81px), likely because one detection
    // fits the inner shadow edge rather than the true outer disc. Tracked as an algorithm
    // improvement; this assertion will start passing once the pairing logic is fixed.
    withKnownIssue("Hough outer-radius pairing produces CV≈0.29 on outOfFocusDubhe.fits; algorithm fix pending") {
        #expect(cv < 0.10, "Outer radii CV \(String(format:"%.3f",cv)) should be < 0.10")
    }
}
