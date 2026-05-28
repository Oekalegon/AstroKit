import Foundation
import Metal
import os

/// Delegates frame registration to either the quad-based or triangle-based processor,
/// selected at runtime via the `registration_algorithm` parameter.
///
/// Accepted values for `registration_algorithm`:
/// - `"quad"` (default) — 4-star patterns via `FrameRegistrationProcessor`
/// - `"triangle"` — 3-star patterns via `FrameRegistrationTriangleProcessor`
///
/// All other parameters are forwarded verbatim to the chosen processor, so the full
/// parameter sets of both processors are accepted here.
public struct FrameRegistrationDispatchProcessor: Processor {
    public var id: String { "frame_registration_dispatch" }
    public init() {}

    public func execute(
        inputs:       [String: ProcessData],
        outputs:      inout [String: ProcessData],
        parameters:   [String: Parameter],
        device:       MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        let algorithm = parameters["registration_algorithm"]?.stringValue ?? "quad"

        switch algorithm {
        case "triangle":
            Logger.processor.info("FrameRegistrationDispatch: using triangle algorithm")
            try FrameRegistrationTriangleProcessor().execute(
                inputs: inputs, outputs: &outputs,
                parameters: parameters, device: device, commandQueue: commandQueue
            )
        default:
            if algorithm != "quad" {
                Logger.processor.warning("FrameRegistrationDispatch: unknown algorithm '\(algorithm)', falling back to quad")
            } else {
                Logger.processor.info("FrameRegistrationDispatch: using quad algorithm")
            }
            try FrameRegistrationProcessor().execute(
                inputs: inputs, outputs: &outputs,
                parameters: parameters, device: device, commandQueue: commandQueue
            )
        }
    }
}
