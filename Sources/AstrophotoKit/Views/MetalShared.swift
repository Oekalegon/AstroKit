import Metal

/// Shared Metal device, command queue, and pipeline states.
/// All properties are allocated once on first access and reused across all views.
enum MetalShared {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue: MTLCommandQueue? = device?.makeCommandQueue()

    static let crossSectionColumnPipeline: MTLComputePipelineState? = makePipeline("cross_section_column")
    static let crossSectionRowPipeline: MTLComputePipelineState?    = makePipeline("cross_section_row")

    private static func makePipeline(_ name: String) -> MTLComputePipelineState? {
        guard let device,
              let library = AstrophotoKit.makeShaderLibrary(device: device),
              let fn = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }
}
