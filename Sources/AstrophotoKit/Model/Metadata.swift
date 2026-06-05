import Foundation

/// A key for metadata.
public protocol MetadataKey: Identifiable, Equatable {

    /// The type of the value for this metadata key.
    var valueType: any Any.Type { get }
}

/// A value for metadata.
public protocol Metadata: Identifiable, Equatable {

    /// The key for this metadata.
    var key: any MetadataKey { get }
}
