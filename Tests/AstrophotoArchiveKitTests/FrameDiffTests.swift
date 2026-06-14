import Testing
import Foundation
@testable import AstrophotoArchiveKit

// MARK: - ParameterValue

@Suite("FrameDiff.ParameterValue — typed parsing and equality")
struct ParameterValueTests {

    @Test("'true'/'false' parse as booleans, case-insensitive")
    func boolParsing() {
        #expect(FrameDiff.ParameterValue("true")  == .boolean(true))
        #expect(FrameDiff.ParameterValue("True")  == .boolean(true))
        #expect(FrameDiff.ParameterValue("TRUE")  == .boolean(true))
        #expect(FrameDiff.ParameterValue("false") == .boolean(false))
        #expect(FrameDiff.ParameterValue("False") == .boolean(false))
        #expect(FrameDiff.ParameterValue("FALSE") == .boolean(false))
    }

    @Test("whole-number strings parse as integers")
    func intParsing() {
        #expect(FrameDiff.ParameterValue("0")   == .integer(0))
        #expect(FrameDiff.ParameterValue("42")  == .integer(42))
        #expect(FrameDiff.ParameterValue("-5")  == .integer(-5))
        #expect(FrameDiff.ParameterValue("100") == .integer(100))
    }

    @Test("decimal strings parse as doubles")
    func doubleParsing() {
        #expect(FrameDiff.ParameterValue("1.5")  == .double(1.5))
        #expect(FrameDiff.ParameterValue("3.14") == .double(3.14))
        #expect(FrameDiff.ParameterValue("-2.5") == .double(-2.5))
        #expect(FrameDiff.ParameterValue("3.0")  == .double(3.0))
    }

    @Test("non-numeric strings fall back to string case")
    func stringFallback() {
        #expect(FrameDiff.ParameterValue("average")    == .string("average"))
        #expect(FrameDiff.ParameterValue("sigma_clip") == .string("sigma_clip"))
        #expect(FrameDiff.ParameterValue("none")       == .string("none"))
        #expect(FrameDiff.ParameterValue("")           == .string(""))
    }

    @Test("integer and double are equal when numerically identical")
    func crossTypeNumericEquality() {
        #expect(FrameDiff.ParameterValue("3")   == FrameDiff.ParameterValue("3.0"))
        #expect(FrameDiff.ParameterValue("3.0") == FrameDiff.ParameterValue("3"))
        #expect(FrameDiff.ParameterValue("100") == FrameDiff.ParameterValue("100.0"))
        #expect(FrameDiff.ParameterValue("-1")  == FrameDiff.ParameterValue("-1.0"))
    }

    @Test("numerically unequal values are not equal")
    func numericInequality() {
        #expect(FrameDiff.ParameterValue("3")   != FrameDiff.ParameterValue("4"))
        #expect(FrameDiff.ParameterValue("3.0") != FrameDiff.ParameterValue("3.5"))
    }

    @Test("boolean is not equal to integer 1/0")
    func boolNotEqualToInt() {
        #expect(FrameDiff.ParameterValue("true")  != FrameDiff.ParameterValue("1"))
        #expect(FrameDiff.ParameterValue("false") != FrameDiff.ParameterValue("0"))
    }

    @Test("description round-trips each type correctly")
    func descriptionRoundTrip() {
        #expect(FrameDiff.ParameterValue("true").description    == "true")
        #expect(FrameDiff.ParameterValue("false").description   == "false")
        #expect(FrameDiff.ParameterValue("42").description      == "42")
        #expect(FrameDiff.ParameterValue("3.14").description    == "3.14")
        #expect(FrameDiff.ParameterValue("average").description == "average")
    }

    @Test("integer description has no decimal point")
    func integerDescriptionHasNoDecimal() {
        #expect(!FrameDiff.ParameterValue("42").description.contains("."))
    }

    @Test("double description always contains a decimal point or exponent")
    func doubleDescriptionHasDecimalOrExponent() {
        let d = FrameDiff.ParameterValue("3.0").description
        #expect(d.contains(".") || d.contains("e"))
    }

    @Test("Int.max parses as integer and description contains no decimal point")
    func intMaxDescription() {
        let v = FrameDiff.ParameterValue("\(Int.max)")
        #expect(v == .integer(Int.max))
        #expect(v.description == "\(Int.max)")
        #expect(!v.description.contains("."))
    }

    @Test("scientific notation string parses as double and description preserves the exponent")
    func scientificNotationDescription() {
        let v = FrameDiff.ParameterValue("1e-10")
        #expect(v == .double(1e-10))
        #expect(v.description.contains("e"), "exponent notation must be preserved")
        #expect(!v.description.hasSuffix(".0"), "must not append .0 to a value already in exponent form")
    }

    @Test("'nan' and 'inf' strings parse as double and description omits spurious .0 suffix")
    func nanAndInfDescription() {
        // Swift's Double(_:) accepts "nan", "NaN", "inf", "-inf" — they become .double,
        // not .string. The description must not append ".0" to these non-finite values.
        #expect(FrameDiff.ParameterValue("nan").description  == "nan")
        #expect(FrameDiff.ParameterValue("NaN").description  == "nan")
        #expect(FrameDiff.ParameterValue("inf").description  == "inf")
        #expect(FrameDiff.ParameterValue("-inf").description == "-inf")
    }
}

// MARK: - Archive.diff

@Suite("Archive.diff — parameter and quality diffs between frame versions")
struct ArchiveDiffTests {

    // Uses an unknown pipeline ID so recordProcessingRun stores parameters verbatim,
    // giving us full control over the stored values for testing diff logic in isolation.
    private static let rawPipelineID = "test_diff_raw_storage"

    @Test("identical parameter sets produce an empty diff")
    func identicalParamsEmptyDiff() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-equal")
        defer { try? FileManager.default.removeItem(at: root) }

        let params = ["method": "average", "count": "10"]
        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: params, params2: params)

        let diff = try await archive.diff(v2, predecessor: v1)
        #expect(diff.parameterChanges.isEmpty)
    }

    @Test("changed parameter appears exactly once in diff with correct from/to values")
    func changedParamIsReported() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-changed")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: ["method": "average"],
                                                  params2: ["method": "sum"])

        let diff = try await archive.diff(v2, predecessor: v1)
        #expect(diff.parameterChanges.count == 1)
        let change = try #require(diff.parameterChanges.first)
        #expect(change.key  == "method")
        #expect(change.from == .string("average"))
        #expect(change.to   == .string("sum"))
    }

    @Test("numerically equal values stored as different strings do not appear in diff")
    func numericEqualitySkipsDiff() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-numeric")
        defer { try? FileManager.default.removeItem(at: root) }

        // "3" and "3.0" are numerically the same; the diff must treat them as equal.
        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: ["sigma": "3"],
                                                  params2: ["sigma": "3.0"])

        let diff = try await archive.diff(v2, predecessor: v1)
        #expect(diff.parameterChanges.isEmpty,
                "\"3\" and \"3.0\" are numerically equal and must not appear as a diff")
    }

    @Test("only the changed parameter appears when all others are unchanged")
    func onlyChangedParamAppears() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-one-change")
        defer { try? FileManager.default.removeItem(at: root) }

        let shared: [String: String] = [
            "normalisation":   "none",
            "pixel_rejection": "sigma_clip",
            "rejection_low":   "3.0",
            "rejection_high":  "3.0",
        ]
        var p1 = shared; p1["method"] = "average"
        var p2 = shared; p2["method"] = "sum"

        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: p1, params2: p2)

        let diff = try await archive.diff(v2, predecessor: v1)
        #expect(diff.parameterChanges.count == 1)
        #expect(diff.parameterChanges.first?.key == "method")
    }

    @Test("parameter absent in predecessor shows from = nil")
    func paramAbsentInPredecessorShowsNilFrom() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-nil-from")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: [:],
                                                  params2: ["method": "sum"])

        let diff = try await archive.diff(v2, predecessor: v1)
        let change = try #require(diff.parameterChanges.first { $0.key == "method" })
        #expect(change.from == nil)
        #expect(change.to   == .string("sum"))
    }

    @Test("parameter absent in successor shows to = nil")
    func paramAbsentInSuccessorShowsNilTo() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-nil-to")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: ["method": "average"],
                                                  params2: [:])

        let diff = try await archive.diff(v2, predecessor: v1)
        let change = try #require(diff.parameterChanges.first { $0.key == "method" })
        #expect(change.from == .string("average"))
        #expect(change.to   == nil)
    }

    @Test("diff.from and diff.to identify the correct frames")
    func diffFromToFrameIDs() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-framerefs")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2) = try await makeVersionPair(archive: archive, root: root,
                                                  params1: ["method": "average"],
                                                  params2: ["method": "sum"])

        let diff = try await archive.diff(v2, predecessor: v1)
        #expect(diff.from.id == v1.id)
        #expect(diff.to.id   == v2.id)
    }

    @Test("frame with no processing run produces an empty parameter diff")
    func noRunProducesEmptyDiff() async throws {
        let (archive, root) = try makeTempArchive(prefix: "diff-no-run")
        defer { try? FileManager.default.removeItem(at: root) }

        let src1 = root.appendingPathComponent("v1.fits")
        let src2 = root.appendingPathComponent("v2.fits")
        try writeTinyFITS(to: src1, dateObs: "2025-06-01T10:00:00", stacked: true)
        try writeTinyFITS(to: src2, dateObs: "2025-06-01T11:00:00", stacked: true)

        let (v1, _) = try await archive.add(fitsFile: src1)
        let (v2, _) = try await archive.add(fitsFile: src2, supersedesID: v1.id)

        let diff = try await archive.diff(v2, predecessor: v1)
        #expect(diff.parameterChanges.isEmpty)
        #expect(diff.inputsAdded.isEmpty)
        #expect(diff.inputsRemoved.isEmpty)
    }

    // MARK: - Helper

    private func makeVersionPair(
        archive: Archive,
        root: URL,
        params1: [String: String],
        params2: [String: String]
    ) async throws -> (ArchivedFrame, ArchivedFrame) {
        let run1 = try await archive.recordProcessingRun(
            pipelineID: Self.rawPipelineID, parameters: params1, inputs: [])
        let run2 = try await archive.recordProcessingRun(
            pipelineID: Self.rawPipelineID, parameters: params2, inputs: [])

        let src1 = root.appendingPathComponent("v1-\(UUID().uuidString).fits")
        let src2 = root.appendingPathComponent("v2-\(UUID().uuidString).fits")
        try writeTinyFITS(to: src1, dateObs: "2025-06-01T10:00:00", stacked: true)
        try writeTinyFITS(to: src2, dateObs: "2025-06-01T11:00:00", stacked: true)

        let (v1, _) = try await archive.add(fitsFile: src1, processingRunID: run1.id)
        let (v2, _) = try await archive.add(fitsFile: src2, processingRunID: run2.id,
                                             supersedesID: v1.id)
        return (v1, v2)
    }
}
