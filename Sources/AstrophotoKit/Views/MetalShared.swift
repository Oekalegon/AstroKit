import Metal

/// Shared Metal device and command queue.
/// Device and queue creation is expensive — these are allocated once and reused across all views.
enum MetalShared {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue: MTLCommandQueue? = device?.makeCommandQueue()
}
