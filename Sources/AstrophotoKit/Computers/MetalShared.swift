import Metal
import OSLog

private let logger = Logger(subsystem: "com.astrophotokit", category: "MetalShared")

/// Shared Metal device, command queue, and pipeline states.
/// All properties are allocated once on first access and reused across all views.
enum MetalShared {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue: MTLCommandQueue? = device?.makeCommandQueue()

    static let crossSectionColumnPipeline: MTLComputePipelineState? = makePipeline("cross_section_column")
    static let crossSectionRowPipeline: MTLComputePipelineState?    = makePipeline("cross_section_row")

    // MARK: - Private

    private static func makePipeline(_ name: String) -> MTLComputePipelineState? {
        guard let device,
              let library = crossSectionLibrary,
              let fn = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }

    /// Loads CrossSectionShader.metal as its own MTLLibrary, independent of the
    /// combined makeShaderLibrary path (which concatenates all shaders and can fail
    /// to compile in environments where the full combined source has conflicts).
    ///
    /// Returns nil — and logs an error — if the source file cannot be found in any
    /// bundle candidate. Cross-section views show empty charts in that case, making
    /// the failure visible rather than silently serving a stale inline copy.
    private static let crossSectionLibrary: MTLLibrary? = {
        guard let device else { return nil }
        let candidates: [(Bundle, String?)] = [
            (Bundle.module, nil),
            (Bundle.module, "Shaders"),
            (Bundle.main,   nil),
            (Bundle.main,   "Shaders"),
        ]
        for (bundle, subdir) in candidates {
            if let url = bundle.url(forResource: "CrossSectionShader",
                                    withExtension: "metal",
                                    subdirectory: subdir),
               let src = try? String(contentsOf: url, encoding: .utf8),
               let lib = try? device.makeLibrary(source: src, options: nil) {
                return lib
            }
        }
        logger.error("CrossSectionShader.metal not found in any bundle candidate — cross-section views will be empty")
        return nil
    }()
}
