import Foundation
import Metal

/// A frame is a piece of data that represents a single image.
/// 
/// A frame can be a bias frame, a dark frame, a flat frame, 
/// a dark flat frame, a light frame, an intermediate frame, 
/// or a processed light frame.
public struct Frame: ProcessData {

    /// The unique identifier for this frame.
    public let identifier: UUID = UUID()

    /// The date and time this frame was instantiated.
    public private(set) var instantiatedAt: Date?

    /// Whether this frame has been instantiated.
    public var isInstantiated: Bool { return instantiatedAt != nil }

    /// Whether this frame is a collection. This will always return `false` for frames.
    /// This represents individual frames.
    public var isCollection: Bool { return false }

    /// The number of items in this collection.
    /// This will always return `1` for frames.
    public var collectionCount: Int { return 1 }

    /// The input links for this frame.
    /// 
    /// The input links are the links (process parameters) to which this frame is connected.
    /// They identify the process and the parameter name into which this data is fed.
    public var inputLinks: [ProcessDataLink]

    /// The output link for this frame.
    /// 
    /// The frame can be produced by only one process, so there is only one output link.
    /// It is connected to the process that produces this frame with a name reference.
    /// Named references are needed when a process produces multiple outputs and the 
    /// output data needs to be referenced by name.
    public var outputLink: ProcessDataLink?

    /// The links for this frame.
    /// 
    /// The links are the links (process parameters) to which this frame is connected.
    /// They identify the process and the parameter name into which this data is fed or taken from.
    private var links: [ProcessDataLink] = []

    /// The Metal texture for this frame.
    /// 
    /// The texture is the raw image data for the frame.
    public var texture: MTLTexture? {
        didSet {
            // When the texture is set, and the data for the frame is available 
            // the frame is instantiated. This happens when the process creating the frame
            // has been completed and the frame data is available.
            if texture != nil {
                instantiatedAt = Date()
            } else {
                instantiatedAt = nil
            }
        }
    }

    /// The metadata for this frame.
    /// 
    /// The metadata is a dictionary of frame metadata keys and values.
    private let metadata: [FrameMetadataKey: Any]

    /// The type of frame. This is a metadata key but is required for frames.
    /// 
    /// For instance, a frame can be a bias frame, a dark frame, 
    /// a flat frame, a dark flat frame, a light frame, 
    /// an intermediate frame, or a processed light frame.
    public var type: FrameType {
        return metadata(for: FrameMetadataKey.type) as? FrameType ?? .unknown
    }

    /// The filter used for the frame.
    /// 
    /// For instance, a frame can be a red frame, a green frame, a blue frame, 
    /// a narrowband frame.
    public var filter: Filter {
        return metadata(for: FrameMetadataKey.filter) as? Filter ?? .unknown
    }

    /// The color space of the frame, derived from the texture's pixel format.
    /// 
    /// If a texture is available, the color space is determined from its pixel format
    /// (grayscale for single-channel formats, RGB for multi-channel formats).
    /// If no texture is available or the format cannot be determined, falls back to metadata.
    public var colorSpace: ColorSpace {
        if let texture = texture,
           let colorSpace = ColorSpace.from(metalPixelFormat: texture.pixelFormat) {
            return colorSpace
        }
        return metadata(for: FrameMetadataKey.colorSpace) as? ColorSpace ?? .unknown
    }

    /// The data type of the frame, derived from the texture's pixel format.
    public var dataType: FITSDataType? {
        guard let texture = texture else {
            return metadata(for: FrameMetadataKey.dataType) as? FITSDataType ?? nil
        }
        return FITSDataType.from(metalPixelFormat: texture.pixelFormat)
    }

    /// The file path of the source FITS file, if the frame was loaded from disk.
    public var filePath: String? {
        return metadata(for: FrameMetadataKey.filePath) as? String
    }

    /// The observation timestamp from DATE-OBS, if available in the FITS header.
    public var timestamp: Date? {
        return metadata(for: FrameMetadataKey.timestamp) as? Date
    }

    /// The exposure time in seconds, if available in the FITS header.
    public var exposureTime: Double? {
        return metadata(for: FrameMetadataKey.exposureTime) as? Double
    }

    /// The camera gain, if available in the FITS header.
    public var gain: Double? {
        return metadata(for: FrameMetadataKey.gain) as? Double
    }

    /// The camera offset (bias pedestal), if available in the FITS header.
    public var offset: Double? {
        return metadata(for: FrameMetadataKey.offset) as? Double
    }

    /// The canonical display name for the filter.
    /// For recognised FITS filters this is the normalised name (e.g. "Hɑ", "SII", "OIII").
    /// For unrecognised filter strings it is the raw trimmed FITS value so nothing is lost.
    /// Nil when no filter information was available.
    public var filterName: String? {
        return metadata(for: FrameMetadataKey.filterName) as? String
    }

    /// The original minimum pixel value (ADU) before normalization to [0, 1].
    /// Populated when the Frame is loaded from a FITS file.
    public var fitsMinValue: Double? {
        return metadata(for: FrameMetadataKey.fitsMinValue) as? Double
    }

    /// The original maximum pixel value (ADU) before normalization to [0, 1].
    /// Populated when the Frame is loaded from a FITS file.
    public var fitsMaxValue: Double? {
        return metadata(for: FrameMetadataKey.fitsMaxValue) as? Double
    }

    /// Converts a normalized [0, 1] pixel value back to the original ADU scale.
    /// Returns `nil` if the FITS min/max scale is not available.
    public func toADU(_ normalizedValue: Double) -> Double? {
        guard let minVal = fitsMinValue, let maxVal = fitsMaxValue else { return nil }
        return normalizedValue * (maxVal - minVal) + minVal
    }

    /// Create a new frame.
    /// 
    /// The frame data is not necessarily instantiated during initialization, but
    /// may be provided later. At that point the file will be instantiated.
    /// 
    /// A frame, or other piece of process data, is created when a pipeline is started
    /// even if the image data is not yet available. For instance, in a stacking process,
    /// the stacked output frame is created when the stacking process is started. The stacked
    /// data is then not yet available, but will be made available when the stacking process
    /// has been completed.
    /// - Parameter type: The type of frame.
    /// - Parameter filter: The filter used for the frame.
    /// - Parameter colorSpace: The color space of the frame.
    /// - Parameter dataType: The data type of the frame.
    /// - Parameter texture: The Metal texture for the frame if available.
    /// - Parameter outputProcess: The output link for this frame (the process that produces it).
    /// - Parameter inputProcesses: The input links for this frame (the processes that consume it).
    /// - Parameter filePath: The file path of the source FITS file, if loaded from disk.
    /// - Parameter timestamp: The observation timestamp (DATE-OBS), if available.
    /// - Parameter exposureTime: The exposure time in seconds, if available.
    /// - Parameter gain: The camera gain, if available.
    /// - Parameter offset: The camera offset, if available.
    /// - Parameter filterName: The canonical display name of the filter, if available.
    public init(
        type: FrameType,
        filter: Filter = .none,
        colorSpace: ColorSpace,
        dataType: FITSDataType,
        texture: MTLTexture? = nil,
        outputProcess: ProcessDataLink? = nil,
        inputProcesses: [ProcessDataLink] = [],
        filePath: String? = nil,
        timestamp: Date? = nil,
        exposureTime: Double? = nil,
        gain: Double? = nil,
        offset: Double? = nil,
        filterName: String? = nil,
        fitsMinValue: Double? = nil,
        fitsMaxValue: Double? = nil
    ) {
        self.instantiatedAt = texture != nil ? Date() : nil
        self.texture = texture
        var metadata = [FrameMetadataKey: Any]()
        metadata[FrameMetadataKey.type] = type
        metadata[FrameMetadataKey.filter] = filter
        metadata[FrameMetadataKey.colorSpace] = colorSpace
        metadata[FrameMetadataKey.dataType] = dataType
        if let filePath = filePath { metadata[FrameMetadataKey.filePath] = filePath }
        if let timestamp = timestamp { metadata[FrameMetadataKey.timestamp] = timestamp }
        if let exposureTime = exposureTime { metadata[FrameMetadataKey.exposureTime] = exposureTime }
        if let gain = gain { metadata[FrameMetadataKey.gain] = gain }
        if let offset = offset { metadata[FrameMetadataKey.offset] = offset }
        if let filterName   = filterName   { metadata[FrameMetadataKey.filterName]   = filterName }
        if let fitsMinValue = fitsMinValue { metadata[FrameMetadataKey.fitsMinValue] = fitsMinValue }
        if let fitsMaxValue = fitsMaxValue { metadata[FrameMetadataKey.fitsMaxValue] = fitsMaxValue }
        self.metadata = metadata
        self.outputLink = outputProcess
        self.inputLinks = inputProcesses
    }

    /// Instantiate this frame.
    /// 
    /// This method is used to instantiate the frame.
    /// 
    /// When the frame is instantiated, we assume that the frame data is available and ready to use.
    public mutating func instantiate() {
        self.instantiatedAt = Date()
    }

    /// Add an input link to this frame.
    /// - Parameters:
    ///   - process: The UUID of the process
    ///   - link: The link name (parameter name)
    ///   - type: The type of data
    ///   - collectionMode: How to process collections
    ///   - stepLinkID: The step link ID from the YAML `from` field (e.g., "grayscale.grayscale_frame")
    public mutating func addInputLink(
        process: UUID,
        link: String,
        collectionMode: CollectionMode
    ) {
        guard let outputLink = outputLink else {
            fatalError("Output link is not set for frame")
        }
        // Extract stepLinkID from the output link
        let stepLinkID: String
        if case .output(_, _, _, let linkStepLinkID) = outputLink {
            stepLinkID = linkStepLinkID
        } else {
            fatalError("Output link must be an output case")
        }
        self.inputLinks.append(.input(process: process, link: link, type: .frame, collectionMode: collectionMode, stepLinkID: stepLinkID))
    }

    /// Get the metadata for this frame.
    /// 
    /// The function checks if the key is a valid frame metadata key and returns `nil` if it is not.
    /// - Parameter key: The key of the metadata to get.
    /// - Returns: The metadata value, or nil if the metadata does not exist.
    public func metadata(for key: any MetadataKey) -> Any? {
        guard let key = key as? FrameMetadataKey else { return nil }
        return metadata[key]
    }
}

/// Metadata keys for frames.
public enum FrameMetadataKey: String, MetadataKey {

    /// The type of frame. 
    /// 
    /// For instance, a frame can be a bias frame, a dark frame, 
    /// a flat frame, a dark flat frame, a light frame, 
    /// an intermediate frame, or a processed light frame.
    case type

    /// The color space used for the frame.
    /// 
    /// For instance, a frame can be in greyscale or RGB.
    case colorSpace

    /// The data type used for the frame.
    /// 
    /// For instance, a frame can be a float32, float64, int32, int64, uint32, uint64, etc.
    case dataType

    /// The filter used for the frame.
    /// 
    /// For instance, a frame can be a red frame, a green frame, a blue frame, 
    /// a narrowband frame.
    case filter

    /// The exposure time of the frame in seconds. If the frame is the result of a
    /// stacking process, the exposure time is the total exposure time of the stacked frames.
    case exposureTime

    /// The file path of the source FITS file, if the frame was loaded from disk.
    case filePath

    /// The observation timestamp (DATE-OBS) of the frame, if available in the FITS header.
    case timestamp

    /// The camera gain used for the frame, if available in the FITS header.
    case gain

    /// The camera offset (bias pedestal) used for the frame, if available in the FITS header.
    case offset

    /// The canonical display name of the filter (e.g. "Ha", "SII", "OIII", "NII").
    /// For known filters this is the normalised name; for unrecognised ones it is the
    /// raw trimmed FITS string so no information is lost.
    case filterName

    /// The minimum pixel value (ADU) from the original FITS file, before [0,1] normalization.
    case fitsMinValue

    /// The maximum pixel value (ADU) from the original FITS file, before [0,1] normalization.
    case fitsMaxValue

    /// The identifier for the metadata key.
    public var id: String {
        return "\(String(describing: Self.self)).\(rawValue)"
    }

    /// The type of the value for this metadata key.
    public var valueType: any Any.Type {
        switch self {
        case .type:
            return FrameType.self
        case .filter:
            return Filter.self
        case .colorSpace:
            return ColorSpace.self
        case .dataType:
            return FITSDataType.self
        case .exposureTime:
            return Double.self
        case .filePath:
            return String.self
        case .timestamp:
            return Date.self
        case .gain:
            return Double.self
        case .offset:
            return Double.self
        case .filterName:
            return String.self
        case .fitsMinValue, .fitsMaxValue:
            return Double.self
        }
    }
}

/// The type of frame.
public enum FrameType: String, Metadata {

    /// A bias frame. 
    case bias

    /// A master bias frame.
    case masterBias

    /// A dark frame.
    case dark

    /// A calibrated dark frame.
    case calibratedDark

    /// A master dark frame.
    case masterDark

    /// A flat frame.
    case flat

    /// A calibrated flat frame.
    case calibratedFlat

    /// A master flat frame.
    case masterFlat

    /// A dark flat frame.
    case darkFlat

    /// A calibrated dark flat frame.
    case calibratedDarkFlat

    /// A master dark flat frame.
    case masterDarkFlat

    /// A light frame.
    case light

    /// An intermediate frame.
    case intermediate

    /// A callibrated light frame.
    case callibratedLight

    /// A processed light frame.
    case processedLight

    /// An unknown frame type.
    case unknown

    /// Used for frame sets that contain multiple frame types.
    case multiple

    /// The key for this metadata value.
    /// Returns the ``FrameMetadataKey.type`` key.
    public var key: any MetadataKey {
        return FrameMetadataKey.type
    }

    /// The identifier for the metadata value.
    public var id: String {
        return "\(self.key).\(String(describing: Self.self)).\(rawValue)"
    }
}

/// The filter used for the frame.
public enum Filter: String, Metadata {

    /// A red filter in a RGBL filter set.
    case red

    /// A green filter in a RGBL filter set.
    case green

    /// A blue filter in a RGBL filter set.
    case blue
    
    /// A luminosity filter in a RGBL filter set.
    case luminosity

    /// A Hɑ filter in a HɑL filter set.
    case Hɑ

    /// A OIII filter in a OIIIL filter set.
    case OIII

    /// A SII filter in a SIIL filter set.
    case SII
    
    /// A V filter in a Johnson UBVRI filter set.
    case V

    /// A B filter in a Johnson UBVRI filter set.
    case B

    /// A U filter in a Johnson UBVRI filter set.
    case U

    /// A R filter in a Johnson UBVRI filter set.
    case R

    /// A I filter in a Johnson UBVRI filter set.
    case I

    /// No filter.
    case none

    /// An unknown filter.
    case unknown

    /// The key for this metadata value.
    /// Returns the ``FrameMetadataKey.filter`` key.
    public var key: any MetadataKey {
        return FrameMetadataKey.filter
    }

    /// The identifier for the metadata key.
    public var id: String {
        return "\(String(describing: Self.self)).\(rawValue)"
    }
}


/// The color space used for the frame.
public enum ColorSpace: String, Metadata {

    /// A greyscale color space.
    case greyscale

    /// A RGB color space.
    case RGB

    /// A binary color space.
    /// 
    /// This is a binary mask encoded as a grayscale image.
    case binary

    /// An unknown color space.
    case unknown

    /// The key for this metadata value.
    /// Returns the ``FrameMetadataKey.colorSpace`` key.
    public var key: any MetadataKey {
        return FrameMetadataKey.colorSpace
    }

    /// The identifier for the metadata key.
    public var id: String {
        return "\(String(describing: Self.self)).\(rawValue)"
    }
    
    /// Creates a ColorSpace from a Metal pixel format.
    /// 
    /// Single-channel formats (e.g., `.r8Unorm`, `.r32Float`) indicate grayscale.
    /// Multi-channel formats (e.g., `.rgba8Unorm`, `.rgba32Float`) indicate RGB.
    /// - Parameter pixelFormat: The Metal pixel format
    /// - Returns: The corresponding ColorSpace, or `nil` if the format is not supported
    static func from(metalPixelFormat pixelFormat: MTLPixelFormat) -> ColorSpace? {
        switch pixelFormat {
        // Single-channel formats (grayscale)
        case .r8Unorm, .r8Uint, .r8Sint,
             .r16Unorm, .r16Uint, .r16Sint, .r16Float,
             .r32Uint, .r32Sint, .r32Float:
            return .greyscale
            
        // Multi-channel formats (RGB/RGBA)
        case .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Uint, .rgba8Sint,
             .rgba16Unorm, .rgba16Uint, .rgba16Sint, .rgba16Float,
             .rgba32Uint, .rgba32Sint, .rgba32Float,
             .rgb9e5Float, .rgb10a2Unorm, .rgb10a2Uint,
             .bgra8Unorm, .bgra8Unorm_srgb:
            return .RGB
            
        // Unsupported formats
        default:
            return nil
        }
    }
} 
