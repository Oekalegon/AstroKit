import Metal

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
    private static let crossSectionLibrary: MTLLibrary? = {
        guard let device else { return nil }
        // Try loading the .metal source file from any known bundle location.
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
        // Inline fallback — guaranteed to work as long as Metal is available.
        return try? device.makeLibrary(source: crossSectionShaderSource, options: nil)
    }()

    /// Verbatim copy of CrossSectionShader.metal used as an inline compilation fallback.
    private static let crossSectionShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void cross_section_column(
        texture2d<float, access::read> tex [[texture(0)]],
        device float                  *out [[buffer(0)]],
        constant uint                 &col [[buffer(1)]],
        uint gid [[thread_position_in_grid]]
    ) {
        if (gid >= tex.get_height()) return;
        out[gid] = tex.read(uint2(col, gid)).r;
    }

    kernel void cross_section_row(
        texture2d<float, access::read> tex [[texture(0)]],
        device float                  *out [[buffer(0)]],
        constant uint                 &row [[buffer(1)]],
        uint gid [[thread_position_in_grid]]
    ) {
        if (gid >= tex.get_width()) return;
        out[gid] = tex.read(uint2(gid, row)).r;
    }
    """
}
