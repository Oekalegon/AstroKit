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
    private var metadata: [FrameMetadataKey: Any]

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
    /// This is the camera gain *setting* (e.g. 0–300 for ZWO cameras), not the
    /// physical conversion factor. See `egain` for the e⁻/ADU conversion factor.
    public var gain: Double? {
        return metadata(for: FrameMetadataKey.gain) as? Double
    }

    /// The camera offset (bias pedestal), if available in the FITS header.
    public var offset: Double? {
        return metadata(for: FrameMetadataKey.offset) as? Double
    }

    /// The electron conversion factor in electrons per ADU (e⁻/ADU), from the FITS
    /// `EGAIN` keyword. Use this to convert ADU values to electrons, which are
    /// camera-independent and physically meaningful.
    public var egain: Double? {
        return metadata(for: FrameMetadataKey.egain) as? Double
    }

    /// The plate scale in arcseconds per pixel, from the FITS `PIXSCALE` keyword.
    /// Reflects the combined optical system (telescope focal length + sensor pixel size).
    public var pixelScale: Double? {
        return metadata(for: FrameMetadataKey.pixelScale) as? Double
    }

    /// The target object name from the FITS `OBJECT` keyword, if available.
    public var objectName: String? {
        return metadata(for: FrameMetadataKey.objectName) as? String
    }

    /// The camera / instrument name from the FITS `INSTRUME` keyword, if available.
    public var camera: String? {
        return metadata(for: FrameMetadataKey.camera) as? String
    }

    /// The telescope name from the FITS `TELESCOP` keyword, if available.
    public var telescope: String? {
        return metadata(for: FrameMetadataKey.telescope) as? String
    }

    /// The observatory / site name from the FITS `OBSERVAT` keyword, if available.
    public var site: String? {
        return metadata(for: FrameMetadataKey.site) as? String
    }

    /// The CCD/sensor temperature in degrees Celsius, from the FITS `CCD-TEMP` or `CCDTEMP` keyword.
    public var ccdTemperature: Double? {
        return metadata(for: FrameMetadataKey.ccdTemperature) as? Double
    }

    /// The processing level of the frame: "raw", "calibrated", "stacked", or "stretched".
    /// Derived from AstrophotoKit FITS keywords: `STRETCHD`, `STACKED`, `CALIBRAT`.
    /// Defaults to "raw" when none of these keywords are present.
    public var processingLevel: String {
        return metadata(for: FrameMetadataKey.processingLevel) as? String ?? "raw"
    }

    /// Injects an EGAIN value from an external source (e.g. the archive camera_profiles table)
    /// when the FITS header did not carry an `EGAIN` keyword. Has no effect if egain is already set.
    public mutating func injectEgainIfMissing(_ egain: Double) {
        guard metadata[FrameMetadataKey.egain] == nil else { return }
        metadata[FrameMetadataKey.egain] = egain
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
    /// Note: ADU values are camera-specific (depend on bit depth and gain setting).
    /// Use `toElectrons(_:)` for cross-camera comparable values when `egain` is available.
    public func toADU(_ normalizedValue: Double) -> Double? {
        guard let minVal = fitsMinValue, let maxVal = fitsMaxValue else { return nil }
        return normalizedValue * (maxVal - minVal) + minVal
    }

    /// Converts a normalized [0, 1] pixel value to electrons using the EGAIN factor.
    /// Formula: `(adu - offset) × egain`, where offset defaults to 0 when not available.
    /// Returns `nil` if FITS scale info or EGAIN is not available.
    public func toElectrons(_ normalizedValue: Double) -> Double? {
        guard let adu = toADU(normalizedValue), let eg = egain else { return nil }
        let off = offset ?? 0.0
        return (adu - off) * eg
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
    /// - Parameter egain: The electron conversion factor in e⁻/ADU (FITS `EGAIN`), if available.
    /// - Parameter pixelScale: The plate scale in arcseconds per pixel (FITS `PIXSCALE`), if available.
    /// - Parameter objectName: The target object name (FITS `OBJECT`), if available.
    /// - Parameter camera: The camera / instrument name (FITS `INSTRUME`), if available.
    /// - Parameter telescope: The telescope name (FITS `TELESCOP`), if available.
    /// - Parameter site: The observatory / site name (FITS `OBSERVAT`), if available.
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
        fitsMaxValue: Double? = nil,
        egain: Double? = nil,
        pixelScale: Double? = nil,
        objectName: String? = nil,
        camera: String? = nil,
        telescope: String? = nil,
        site: String? = nil,
        ccdTemperature: Double? = nil,
        processingLevel: String? = nil
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
        if let filterName      = filterName      { metadata[FrameMetadataKey.filterName]      = filterName }
        if let fitsMinValue    = fitsMinValue    { metadata[FrameMetadataKey.fitsMinValue]    = fitsMinValue }
        if let fitsMaxValue    = fitsMaxValue    { metadata[FrameMetadataKey.fitsMaxValue]    = fitsMaxValue }
        if let egain           = egain           { metadata[FrameMetadataKey.egain]           = egain }
        if let pixelScale      = pixelScale      { metadata[FrameMetadataKey.pixelScale]      = pixelScale }
        if let objectName      = objectName      { metadata[FrameMetadataKey.objectName]      = objectName }
        if let camera          = camera          { metadata[FrameMetadataKey.camera]          = camera }
        if let telescope       = telescope       { metadata[FrameMetadataKey.telescope]       = telescope }
        if let site            = site            { metadata[FrameMetadataKey.site]            = site }
        if let ccdTemperature  = ccdTemperature  { metadata[FrameMetadataKey.ccdTemperature]  = ccdTemperature }
        if let processingLevel = processingLevel { metadata[FrameMetadataKey.processingLevel] = processingLevel }
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
    /// This is the camera gain *setting* (FITS `GAIN`), not the e⁻/ADU factor. See `egain`.
    case gain

    /// The camera offset (bias pedestal) used for the frame, if available in the FITS header.
    case offset

    /// The electron conversion factor in electrons per ADU (e⁻/ADU), from the FITS `EGAIN` keyword.
    case egain

    /// The canonical display name of the filter (e.g. "Ha", "SII", "OIII", "NII").
    /// For known filters this is the normalised name; for unrecognised ones it is the
    /// raw trimmed FITS string so no information is lost.
    case filterName

    /// The minimum pixel value (ADU) from the original FITS file, before [0,1] normalization.
    case fitsMinValue

    /// The maximum pixel value (ADU) from the original FITS file, before [0,1] normalization.
    case fitsMaxValue

    /// The plate scale in arcseconds per pixel (FITS `PIXSCALE`), if available.
    case pixelScale

    /// The target object name (FITS `OBJECT`), if available.
    case objectName

    /// The camera / instrument name (FITS `INSTRUME`), if available.
    case camera

    /// The telescope name (FITS `TELESCOP`), if available.
    case telescope

    /// The observatory / site name (FITS `OBSERVAT`), if available.
    case site

    /// The CCD/sensor temperature in °C (FITS `CCD-TEMP` or `CCDTEMP`), if available.
    case ccdTemperature

    /// The processing level of the frame: "raw", "calibrated", "stacked", or "stretched".
    /// Derived from AstrophotoKit FITS keywords (CALIBRAT, STACKED, STRETCHD).
    case processingLevel

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
        case .egain:
            return Double.self
        case .filterName:
            return String.self
        case .fitsMinValue, .fitsMaxValue:
            return Double.self
        case .pixelScale:
            return Double.self
        case .objectName, .camera, .telescope, .site:
            return String.self
        case .ccdTemperature:
            return Double.self
        case .processingLevel:
            return String.self
        }
    }
}

/// The type of frame.
///
/// Frame types are the five base categories. Processing level (raw, calibrated,
/// stacked, stretched) is tracked separately via the ``FrameMetadataKey/processingLevel``
/// metadata key and the AstrophotoKit FITS keywords `CALIBRAT`, `STACKED`, `STRETCHD`.
public enum FrameType: String, Metadata {

    /// A bias frame.
    case bias

    /// A master bias frame (stacked bias).
    case masterBias

    /// A dark frame.
    case dark

    /// A master dark frame (stacked dark).
    case masterDark

    /// A flat frame.
    case flat

    /// A master flat frame (stacked flat).
    case masterFlat

    /// A dark flat frame.
    case darkFlat

    /// A master dark flat frame (stacked dark flat).
    case masterDarkFlat

    /// A light frame.
    case light

    /// An intermediate frame produced inside a multi-step pipeline.
    case intermediate

    /// A diagnostic frame (e.g. annotated detection overlay).
    case diagnostic

    /// An unknown frame type.
    case unknown

    /// Used for frame sets that contain multiple frame types.
    case multiple

    /// Whether this is a calibration frame type (bias, dark, flat, or dark flat,
    /// including their master variants).
    ///
    /// Calibration frames do not image a sky target, so they carry no meaningful
    /// `OBJECT` name or RA/Dec coordinates.
    public var isCalibrationFrame: Bool {
        switch self {
        case .bias, .masterBias,
             .dark, .masterDark,
             .flat, .masterFlat,
             .darkFlat, .masterDarkFlat:
            return true
        default:
            return false
        }
    }

    /// Returns the master variant of a raw calibration type, or nil if there is none.
    public var masterVariant: FrameType? {
        switch self {
        case .bias:     return .masterBias
        case .dark:     return .masterDark
        case .flat:     return .masterFlat
        case .darkFlat: return .masterDarkFlat
        default:        return nil
        }
    }

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
