import Foundation
import Metal

/// Protocol that processors must conform to
public protocol Processor: Identifiable {
    /// The unique identifier for this processor type
    /// This should match the `type` value in the pipeline step YAML
    var id: String { get }

    /// Execute this processor with the given inputs and parameters
    /// - Parameters:
    ///   - inputs: Dictionary of input name to ProcessData instances
    ///   - outputs: Dictionary of output name to ProcessData instances (to be instantiated, passed as inout)
    ///   - parameters: Dictionary of parameter name to parameter value
    ///   - device: Metal device for GPU operations (can be ignored for CPU-only processors)
    ///   - commandQueue: Metal command queue for GPU operations (can be ignored for CPU-only processors)
    /// - Throws: ProcessorExecutionError if execution fails
    /// - Note: CPU-only processors can ignore the `device` and `commandQueue` parameters
    /// - Note: Processors should instantiate the output ProcessData instances with the actual data
    func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws
}
