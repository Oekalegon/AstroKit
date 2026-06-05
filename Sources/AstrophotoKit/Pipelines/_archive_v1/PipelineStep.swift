import Foundation
import Metal

/// Represents different types of data that can be passed between pipeline steps
public enum PipelineData {
    /// A generic processed data container (can hold single/multiple images, tables, or combinations)
    case processedData(ProcessedDataContainer)
    
    /// A processed image with metadata (preferred for single images)
    case processedImage(ProcessedImage)
    
    /// A Metal texture (2D image data) - legacy support
    case texture(MTLTexture)
    
    /// A FITS image
    case fitsImage(FITSImage)
    
    /// A processed table with metadata (preferred for single tables)
    case processedTable(ProcessedTable)
    
    /// A processed scalar with metadata (preferred for scalars)
    case processedScalar(ProcessedScalar)
    
    /// A data table (for structured data like star catalogs, measurements, etc.) - legacy support
    case table([String: Any])
    
    /// A buffer (for raw data)
    case buffer(MTLBuffer)
    
    /// A scalar value - legacy support
    case scalar(Float)
    
    /// A vector value
    case vector(SIMD2<Float>)
    
    /// A 3D vector value
    case vector3(SIMD3<Float>)
    
    /// A 4D vector value
    case vector4(SIMD4<Float>)
    
    /// Metadata dictionary
    case metadata([String: Any])
}

/// Represents an input to a pipeline step
public struct PipelineStepInput {
    /// The name/identifier of this input
    public let name: String
    
    /// The data for this input
    public let data: PipelineData
    
    /// Optional description of what this input represents
    public let description: String?
    
    public init(name: String, data: PipelineData, description: String? = nil) {
        self.name = name
        self.data = data
        self.description = description
    }
}

/// Represents an output from a pipeline step
public struct PipelineStepOutput {
    /// The name/identifier of this output
    public let name: String
    
    /// The data for this output
    public let data: PipelineData
    
    /// Optional description of what this output represents
    public let description: String?
    
    public init(name: String, data: PipelineData, description: String? = nil) {
        self.name = name
        self.data = data
        self.description = description
    }
}

/// Protocol that all pipeline steps must conform to
public protocol PipelineStep {
    /// Unique identifier for this step
    var id: String { get }
    
    /// Human-readable name for this step
    var name: String { get }
    
    /// Description of what this step does
    var description: String { get }
    
    /// Names of required inputs (in order)
    var requiredInputs: [String] { get }
    
    /// Names of optional inputs (in order)
    var optionalInputs: [String] { get }
    
    /// Names of outputs this step produces (in order)
    var outputs: [String] { get }
    
    /// Execute this step with the given inputs
    /// - Parameters:
    ///   - inputs: Dictionary of input name to PipelineStepInput
    ///   - device: Metal device for GPU operations
    ///   - commandQueue: Metal command queue for GPU operations
    /// - Returns: Dictionary of output name to PipelineStepOutput
    /// - Throws: PipelineStepError if execution fails
    func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput]
}

/// Errors that can occur during pipeline step execution
public enum PipelineStepError: LocalizedError {
    case missingRequiredInput(String)
    case invalidInputType(String, expected: String)
    case executionFailed(String)
    case metalNotAvailable
    case couldNotCreateResource(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingRequiredInput(let name):
            return "Missing required input: \(name)"
        case .invalidInputType(let name, let expected):
            return "Invalid input type for '\(name)': expected \(expected)"
        case .executionFailed(let message):
            return "Step execution failed: \(message)"
        case .metalNotAvailable:
            return "Metal is not available"
        case .couldNotCreateResource(let message):
            return "Could not create resource: \(message)"
        }
    }
}

/// Helper extension to extract specific data types from PipelineData
public extension PipelineData {
    /// Extract processed data container if this is a processed data container
    var processedData: ProcessedDataContainer? {
        if case .processedData(let data) = self { return data }
        return nil
    }
    
    /// Extract processed image if this is a processed image or processed data container with single image
    var processedImage: ProcessedImage? {
        if case .processedImage(let img) = self { return img }
        if case .processedData(let container) = self { return container.image }
        return nil
    }
    
    /// Extract texture if this is a texture, processed image, or processed data container with image
    var texture: MTLTexture? {
        if case .texture(let tex) = self { return tex }
        if case .processedImage(let img) = self { return img.texture }
        if case .processedData(let container) = self { return container.image?.texture }
        return nil
    }
    
    /// Extract FITS image if this is a FITS image, processed image, or processed data container with image
    var fitsImage: FITSImage? {
        if case .fitsImage(let img) = self { return img }
        if case .processedImage(let img) = self { return img.fitsImage }
        if case .processedData(let container) = self { return container.image?.fitsImage }
        return nil
    }
    
    /// Extract processed table if this is a processed table or processed data container with single table
    var processedTable: ProcessedTable? {
        if case .processedTable(let tbl) = self { return tbl }
        if case .processedData(let container) = self { return container.table }
        return nil
    }
    
    /// Extract processed scalar if this is a processed scalar
    var processedScalar: ProcessedScalar? {
        if case .processedScalar(let scalar) = self { return scalar }
        return nil
    }
    
    /// Extract scalar if this is a scalar or processed scalar
    var scalar: Float? {
        if case .scalar(let val) = self { return val }
        if case .processedScalar(let processedScalar) = self { return processedScalar.value }
        return nil
    }
    
    /// Extract table if this is a table, processed table, or processed data container with table
    var table: [String: Any]? {
        if case .table(let tbl) = self { return tbl }
        if case .processedTable(let processedTbl) = self { return processedTbl.data }
        if case .processedData(let container) = self { return container.table?.data }
        return nil
    }
    
    /// Extract buffer if this is a buffer
    var buffer: MTLBuffer? {
        if case .buffer(let buf) = self { return buf }
        return nil
    }
    
    /// Extract vector if this is a vector
    var vector: SIMD2<Float>? {
        if case .vector(let vec) = self { return vec }
        return nil
    }
    
    /// Extract vector3 if this is a vector3
    var vector3: SIMD3<Float>? {
        if case .vector3(let vec) = self { return vec }
        return nil
    }
    
    /// Extract vector4 if this is a vector4
    var vector4: SIMD4<Float>? {
        if case .vector4(let vec) = self { return vec }
        return nil
    }
    
    /// Extract metadata if this is metadata
    var metadata: [String: Any]? {
        if case .metadata(let meta) = self { return meta }
        return nil
    }
}

