import Foundation

/// Parameter value that can be an Int, Double, or String
public enum Parameter: Codable, Equatable {
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ParameterValue must be an Int, Double, or String"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    /// Get the value as a Double if possible
    public var doubleValue: Double? {
        switch self {
        case .int(let value):
            return Double(value)
        case .double(let value):
            return value
        case .string(let value):
            return Double(value)
        }
    }

    /// Get the value as an Int if possible
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        }
    }

    /// Get the value as a String
    public var stringValue: String {
        switch self {
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }
}

/// Parameter specification for a pipeline step
/// Parameters are configuration values that can be adjusted between runs
public struct ParameterSpec: Codable {
    /// The parameter name in the step
    public let name: String

    /// The source of the parameter value
    /// Can be:
    /// - A pipeline input name (e.g., "blur_radius")
    /// - null/omitted to use step's default value
    public let from: String?

    /// Optional default value if not provided (can be Int, Double, or String)
    public let defaultValue: Parameter?

    /// Optional description
    public let description: String?

    public init(
        name: String,
        from: String? = nil,
        defaultValue: Parameter? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.from = from
        self.defaultValue = defaultValue
        self.description = description
    }

    /// Convenience initializer with Int default value
    public init(
        name: String,
        from: String? = nil,
        defaultValueInt: Int? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.from = from
        self.defaultValue = defaultValueInt.map { .int($0) }
        self.description = description
    }

    /// Convenience initializer with Double default value
    public init(
        name: String,
        from: String? = nil,
        defaultValueDouble: Double? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.from = from
        self.defaultValue = defaultValueDouble.map { .double($0) }
        self.description = description
    }

    /// Convenience initializer with String default value
    public init(
        name: String,
        from: String? = nil,
        defaultValueString: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.from = from
        self.defaultValue = defaultValueString.map { .string($0) }
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name
        case from
        case defaultValue = "default_value"
        case description
    }
}