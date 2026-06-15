import Testing
import Foundation
import AstrophotoKit
@testable import AstrophotoArchiveKit

@Suite("recordProcessingRun — parameter canonicalization against YAML spec")
struct ParameterCanonicalizationTests {

    // Register a throwaway pipeline for each test so we control the spec exactly.
    // The unique suffix prevents registry collisions when tests run in parallel.
    private func withTestPipeline<T>(
        yaml: String,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let pipeline = try Pipeline.load(from: yaml)
        PipelineRegistry.shared.register(pipeline: pipeline)
        defer { PipelineRegistry.shared.remove(id: pipeline.id) }
        return try await body(pipeline.id)
    }

    private func simpleYAML(id: String) -> String {
        """
        id: \(id)
        name: Test
        steps:
          - id: step1
            type: test
            dataInputs: []
            parameters:
              - name: method
                from: method
                default_value: average
              - name: count
                from: count
                default_value: 10
              - name: threshold
                from: threshold
                default_value: 3.0
            outputs: []
        """
    }

    // MARK: - Unknown keys

    @Test("unknown keys are dropped and known keys are stored")
    func unknownKeysDropped() async throws {
        let id = "test-canon-unknown-\(UUID().uuidString)"
        try await withTestPipeline(yaml: simpleYAML(id: id)) { pipelineID in
            let (archive, root) = try makeTempArchive(prefix: "canon-unknown")
            defer { try? FileManager.default.removeItem(at: root) }

            let run = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: [
                    "method":         "sum",     // valid
                    "stacking_method": "mean",   // unknown — must be dropped
                    "combine_method":  "median", // unknown — must be dropped
                ],
                inputs: []
            )

            #expect(run.parameters["method"]         == "sum")
            #expect(run.parameters["stacking_method"] == nil)
            #expect(run.parameters["combine_method"]  == nil)
        }
    }

    // MARK: - Default filling

    @Test("YAML defaults are stored for omitted parameters")
    func defaultsFilledForOmittedParams() async throws {
        let id = "test-canon-defaults-\(UUID().uuidString)"
        try await withTestPipeline(yaml: simpleYAML(id: id)) { pipelineID in
            let (archive, root) = try makeTempArchive(prefix: "canon-defaults")
            defer { try? FileManager.default.removeItem(at: root) }

            // Only supply `method`; `count` and `threshold` should be filled from YAML.
            let run = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: ["method": "sum"],
                inputs: []
            )

            #expect(run.parameters["method"]    == "sum")
            #expect(run.parameters["count"]     == "10")
            #expect(run.parameters["threshold"] == "3.0")
        }
    }

    @Test("explicit caller value overrides YAML default")
    func callerValueOverridesDefault() async throws {
        let id = "test-canon-override-\(UUID().uuidString)"
        try await withTestPipeline(yaml: simpleYAML(id: id)) { pipelineID in
            let (archive, root) = try makeTempArchive(prefix: "canon-override")
            defer { try? FileManager.default.removeItem(at: root) }

            let run = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: ["method": "median", "count": "25", "threshold": "2.5"],
                inputs: []
            )

            #expect(run.parameters["method"]    == "median")
            #expect(run.parameters["count"]     == "25")
            #expect(run.parameters["threshold"] == "2.5")
        }
    }

    @Test("explicit value equal to YAML default is still stored")
    func explicitDefaultValueIsStored() async throws {
        let id = "test-canon-explicit-default-\(UUID().uuidString)"
        try await withTestPipeline(yaml: simpleYAML(id: id)) { pipelineID in
            let (archive, root) = try makeTempArchive(prefix: "canon-expl-def")
            defer { try? FileManager.default.removeItem(at: root) }

            // Caller explicitly passes the default value — it should still be stored.
            let run = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: ["method": "average"],
                inputs: []
            )

            #expect(run.parameters["method"] == "average")
        }
    }

    // MARK: - Complete key set

    @Test("every run has the same complete key set regardless of which params are omitted")
    func completeKeySetAcrossRuns() async throws {
        let id = "test-canon-keyset-\(UUID().uuidString)"
        try await withTestPipeline(yaml: simpleYAML(id: id)) { pipelineID in
            let (archive, root) = try makeTempArchive(prefix: "canon-keyset")
            defer { try? FileManager.default.removeItem(at: root) }

            // Run with all params explicit.
            let runAll = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: ["method": "sum", "count": "5", "threshold": "2.0"],
                inputs: []
            )
            // Run with no params (all default).
            let runNone = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: [:],
                inputs: []
            )

            #expect(Set(runAll.parameters.keys) == Set(runNone.parameters.keys),
                    "Both runs must have identical key sets so diffs never show (absent)")
        }
    }

    // MARK: - Diff cleanliness

    @Test("diff between two runs that differ only in method shows only method")
    func diffShowsOnlyMethodWhenOnlyMethodChanged() async throws {
        let id = "test-canon-diff-clean-\(UUID().uuidString)"
        try await withTestPipeline(yaml: simpleYAML(id: id)) { pipelineID in
            let (archive, root) = try makeTempArchive(prefix: "canon-diff")
            defer { try? FileManager.default.removeItem(at: root) }

            let run1 = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: ["method": "average"],
                inputs: []
            )
            let run2 = try await archive.recordProcessingRun(
                pipelineID: pipelineID,
                parameters: ["method": "sum"],
                inputs: []
            )

            let src1 = root.appendingPathComponent("v1.fits")
            let src2 = root.appendingPathComponent("v2.fits")
            try writeTinyFITS(to: src1, dateObs: "2025-06-01T10:00:00", stacked: true)
            try writeTinyFITS(to: src2, dateObs: "2025-06-01T11:00:00", stacked: true)

            let (v1, _) = try await archive.add(fitsFile: src1, processingRunID: run1.id)
            let (v2, _) = try await archive.add(fitsFile: src2, processingRunID: run2.id,
                                                 supersedesID: v1.id)

            let diff = try await archive.diff(v2, predecessor: v1)
            #expect(diff.parameterChanges.count == 1,
                    "Only method changed; diff must not show spurious changes for count or threshold")
            #expect(diff.parameterChanges.first?.key == "method")
        }
    }

    // MARK: - Unknown pipeline

    @Test("unknown pipeline ID stores parameters as-is without filtering")
    func unknownPipelineStoresVerbatim() async throws {
        let (archive, root) = try makeTempArchive(prefix: "canon-unknown-pl")
        defer { try? FileManager.default.removeItem(at: root) }

        let run = try await archive.recordProcessingRun(
            pipelineID: "pipeline_that_does_not_exist",
            parameters: ["foo": "bar", "baz": "qux"],
            inputs: []
        )

        // No filtering when the pipeline isn't known.
        #expect(run.parameters["foo"] == "bar")
        #expect(run.parameters["baz"] == "qux")
    }
}
