import ArgumentParser
import AstrophotoKit

extension AP {
    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Show detailed information about a pipeline."
        )

        @Argument(help: "Pipeline ID.")
        var pipelineID: String

        @Flag(name: .shortAndLong, help: "Show detailed explanations for each parameter value.")
        var verbose = false

        func run() async throws {
            guard let pipeline = PipelineRegistry.shared.get(id: pipelineID) else {
                throw ValidationError("Pipeline '\(pipelineID)' not found. Run 'ap list' to see available pipelines.")
            }

            print("Pipeline: \(pipeline.id)")
            print("Name:     \(pipeline.name)")
            if let desc = pipeline.description {
                print("About:    \(desc)")
            }

            // Collect pipeline-level inputs: steps whose `from` has no dot are pipeline inputs
            let inputNames = Array(Set(pipeline.steps.flatMap { step in
                step.dataInputs.compactMap { di in di.from.contains(".") ? nil : di.from }
            })).sorted()
            print("\nInputs (\(inputNames.count)):")
            inputNames.forEach { print("  \($0)") }

            // Collect tunable parameters: param specs that have a `from` (pipeline-level binding)
            let paramSpecs = pipeline.steps.flatMap { $0.parameters }.filter { $0.from != nil }
            let seenParams = paramSpecs.reduce(into: [String: ParameterSpec]()) { acc, spec in
                if acc[spec.from!] == nil { acc[spec.from!] = spec }
            }
            if !seenParams.isEmpty {
                print("\nParameters (--param key=value):")
                for key in seenParams.keys.sorted() {
                    let spec = seenParams[key]!
                    let def = spec.defaultValue.map { " [default: \($0.stringValue)]" } ?? " [required]"
                    let desc = spec.description.map { "  — \($0)" } ?? ""
                    print("  \(key)\(def)\(desc)")
                    if verbose, let lines = Self.verboseHelp[key] {
                        for line in lines { print("      \(line)") }
                    }
                }
            }

            print("\nSteps (\(pipeline.steps.count)):")
            for step in pipeline.steps {
                let label = step.name.map { "\($0)" } ?? step.id
                print("  \(label) [\(step.id)] — processor: \(step.type)")
            }
        }

        // MARK: - Verbose parameter help

        private static let verboseHelp: [String: [String]] = [
            "method": [
                "average        — Mean of all (non-rejected) pixels. Reduces noise by √N. Best general-purpose choice.",
                "sum            — Sum of all pixel values. Total flux scales with frame count; use when absolute counts matter.",
                "median         — Median across frames. Very resistant to outliers (satellites, hot pixels) but slower than average.",
                "max_pixel      — Brightest pixel wins at each position. Useful for star trails or meteor captures.",
                "min_pixel      — Darkest pixel wins at each position. Useful for hot-pixel analysis or minimum-light composites.",
            ],
            "normalisation": [
                "none                    — No correction; frames are combined as-is. Use only when sky background and gain are identical across all frames.",
                "additive                — Subtract the per-frame sky background level so all frames share the same zero-point. Corrects for varying sky brightness (moon, gradients).",
                "multiplicative          — Divide each frame by its median. Equalises overall brightness scale. Useful when frames have different exposure times or transparencies.",
                "additive_scaling        — Subtract background then scale the dynamic range so bright features (e.g. star halos) align across frames.",
                "multiplicative_scaling  — Divide by background then scale to a common brightness range. The most complete correction; recommended when both sky level and gain differ between sessions.",
            ],
            "pixel_rejection": [
                "none       — Keep all pixels. Fastest, but satellites, cosmic rays and hot pixels will appear in the result.",
                "sigma_clip — Single-pass rejection: discard pixels more than N sigma from the mean. Fast and effective for most datasets.",
                "winsorized — Iterative sigma-clip: clips outliers, recalculates statistics, then clips again (3 passes). More robust than sigma_clip for small frame counts or highly variable frames.",
            ],
            "rejection_low": [
                "Pixels more than this many sigma below the mean are rejected.",
                "Smaller values reject more aggressively (more pixels discarded). Typical range: 2.0–4.0.",
                "Lowering below 2.0 can discard faint nebula signal; values above 4.0 let most outliers through.",
            ],
            "rejection_high": [
                "Pixels more than this many sigma above the mean are rejected.",
                "Smaller values clip bright outliers (hot pixels, cosmic rays) more aggressively. Typical range: 2.0–4.0.",
                "A value of 3.0 is a good starting point for most light-pollution-free datasets.",
            ],
            "reference_frame": [
                "-1  — Auto-select: the frame with the highest star-match quality score is used as reference.",
                " N  — Use the N-th frame (0-based) as the reference. All other frames are aligned to it.",
            ],
            "blur_radius": [
                "Gaussian blur applied before star detection to suppress readout noise.",
                "Increase for very noisy frames or small stars; decrease for well-sampled, clean images.",
            ],
            "threshold_value": [
                "Pixel threshold expressed as a multiple of the background sigma.",
                "Higher values detect only bright, well-defined stars. Lower values include faint stars but risk false detections.",
            ],
            "match_threshold": [
                "Maximum L2 distance in quad descriptor space for two quads to be considered a match.",
                "Lower values require tighter geometric agreement; raise if registration fails on sparse star fields.",
            ],
            "min_matches": [
                "Minimum number of matched quad pairs required before a registration is accepted.",
                "Raise this for higher confidence; lower it only if frames have very few stars.",
            ],
            "ransac_iterations": [
                "Number of random trials RANSAC runs when estimating the similarity transform.",
                "More iterations improve robustness against outlier matches but take longer.",
            ],
            "inlier_threshold": [
                "A matched star pair is an inlier if its reprojection error is within this many pixels.",
                "Increase for frames with significant optical distortion or poor seeing.",
            ],
            "max_stars": [
                "Cap on the number of stars used to build quads per frame.",
                "Reducing this speeds up quad formation on dense star fields with minimal accuracy loss.",
            ],
            "min_distance_percent": [
                "Stars closer than this fraction of the image diagonal are merged before quad formation.",
                "Increase if closely-packed double stars or diffraction spikes cause false detections.",
            ],
            "k_neighbors": [
                "Each star forms quads with its K nearest neighbours.",
                "Higher K generates more quads (more robust matching) at the cost of speed.",
            ],
        ]
    }
}
