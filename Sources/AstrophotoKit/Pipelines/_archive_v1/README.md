# Pipeline System v1 (Archived)

This directory contains the original pipeline system implementation that was replaced with a new design based on `docs/_articles/pipeline-design.md`.

**Note:** This directory is excluded from compilation via `Package.swift` to prevent naming conflicts with the new implementation. The code is preserved here for reference only.

## Files

- `Pipeline.swift` - Original pipeline protocol and base implementation
- `PipelineStep.swift` - Original pipeline step protocol and data types
- `PipelineExecutor.swift` - Original synchronous executor
- `PipelineRegistry.swift` - Original pipeline registry
- `StarDetectionPipeline.swift` - Example star detection pipeline
- `Steps/` - All original step implementations:
  - `GaussianBlurStep.swift`
  - `BackgroundEstimationStep.swift`
  - `ThresholdStep.swift`
  - `ErosionStep.swift`
  - `DilationStep.swift`
  - `ConnectedComponentsStep.swift`
  - `QuadsStep.swift`
  - `StarDetectionOverlayStep.swift`

## Why Archived

The original system worked well for the step implementations, but the overall pipeline architecture needed to be redesigned to support:
- YAML-based configuration
- Explicit data flow between steps
- Parallel execution based on dependency graphs
- Async/await execution model
- Progress reporting
- Comprehensive logging
- Cancellation support
- Incremental reprocessing
- Frame collections

The step logic and shader implementations remain unchanged - only the pipeline orchestration layer was redesigned.

