import Foundation

/// A fully type-erased JSON value — the Swift stand-in for Reactotron's
/// arbitrary `payload: any`. Lets the protocol layer decode any command frame
/// without knowing every payload shape, then pick fields out per command type.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public extension JSONValue {
    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
    var doubleValue: Double? { if case let .number(value) = self { return value }; return nil }
    var intValue: Int? { if case let .number(value) = self { return Int(value) }; return nil }
    var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil }
    var objectValue: [String: JSONValue]? { if case let .object(value) = self { return value }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Compact JSON for the timeline (sorted keys, unescaped slashes). Reactotron
    /// serializes functions and some special values as `"~~~ … ~~~"` string
    /// markers; unwrap them so the display reads like Reactotron's desktop —
    /// e.g. `register()`, `null`, `false` instead of quoted marker strings.
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.replacing(/"~~~ (.+?) ~~~"/) { match in String(match.1) }
    }

    /// Pretty-printed (indented) JSON for the expandable object preview, with the
    /// same `~~~ … ~~~` marker repair as `jsonString`.
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.replacing(/"~~~ (.+?) ~~~"/) { match in String(match.1) }
    }
}
