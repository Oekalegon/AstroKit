import Foundation

/// Metadata restriction for data inputs
/// Supports various constraint types for validating input data metadata
public enum MetadataRestriction: Codable {
    /// Allow only specific values (e.g., ["light"] for frame type, ["R", "G", "B"] for filter)
    case allowedValues([String])

    /// Numeric range constraint (e.g., min/max exposure time)
    case range(min: Double?, max: Double?)

    /// Custom constraint (key-value pairs for complex validation)
    case custom([String: String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try to decode as array (allowedValues)
        if let values = try? container.decode([String].self) {
            self = .allowedValues(values)
            return
        }

        // Try to decode as dictionary
        if let dict = try? container.decode([String: AnyCodable].self) {
            if let min = dict["min"]?.doubleValue, let max = dict["max"]?.doubleValue {
                self = .range(min: min, max: max)
            } else {
                let stringDict = dict.mapValues { $0.stringValue ?? "" }
                self = .custom(stringDict)
            }
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "MetadataRestriction must be an array of strings or a dictionary"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .allowedValues(let values):
            try container.encode(values)
        case .range(let min, let max):
            var dict: [String: AnyCodable] = [:]
            if let min = min {
                dict["min"] = AnyCodable(min)
            }
            if let max = max {
                dict["max"] = AnyCodable(max)
            }
            try container.encode(dict)
        case .custom(let dict):
            try container.encode(dict)
        }
    }
}

/// Helper type for encoding/decoding Any values in metadata restrictions
public struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let arrayValue as [Any]:
            let codableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dictValue as [String: Any]:
            let codableDict = dictValue.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnyCodable value cannot be encoded"
                )
            )
        }
    }

    var doubleValue: Double? {
        if let doubleVal = value as? Double { return doubleVal }
        if let intVal = value as? Int { return Double(intVal) }
        return nil
    }

    var stringValue: String? {
        return value as? String
    }
}
