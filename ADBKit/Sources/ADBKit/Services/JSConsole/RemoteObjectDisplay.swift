import Foundation

/// A syntax-colorable span of a rendered value. `kind` is semantic (UI-free);
/// the App maps it to a color, so ADBKit stays free of SwiftUI.
public enum JSTokenKind: Sendable, Equatable {
    case string, number, boolean, null, undefined, function, symbol
    case key, className, punctuation, plain
}

public struct JSToken: Sendable, Equatable {
    public let text: String
    public let kind: JSTokenKind

    public init(_ text: String, _ kind: JSTokenKind) {
        self.text = text
        self.kind = kind
    }
}

/// Pure value→tokens rendering for the console, tuned to how **Hermes** (not V8)
/// serializes over CDP: `bigint` arrives as `type: ""`, `-0`/`Infinity`/`NaN` as
/// `unserializableValue` with no `value`, and `Date`/`Map`/`Set`/`RegExp` as
/// plain `"Object"` (Hermes doesn't tag those subtypes). Kept here so it's
/// unit-tested against recorded payloads.
public extension RemoteObject {
    /// The compact one-line rendering as colorable tokens.
    var tokens: [JSToken] {
        switch type {
        case "string":
            return [JSToken("\"\(value?.stringValue ?? description ?? "")\"", .string)]
        case "boolean":
            return [JSToken(description ?? value.map(CDP.displayString) ?? "false", .boolean)]
        case "number":
            return [JSToken(numberString, .number)]
        case "undefined":
            return [JSToken("undefined", .undefined)]
        case "symbol":
            return [JSToken(description ?? "Symbol()", .symbol)]
        case "function":
            return [JSToken(Self.functionSummary(description), .function)]
        case "object":
            return objectTokens
        default:
            // Hermes reports bigint as `type: ""` — value is in description.
            return [JSToken(description ?? unserializableValue ?? value.map(CDP.displayString) ?? type, .number)]
        }
    }

    /// The plain one-line summary — the tokens joined. Used for search, find,
    /// and copy, so they never diverge from what's shown.
    var inlineSummary: String { tokens.map(\.text).joined() }

    private var numberString: String {
        // -0 / Infinity / NaN come back via description/unserializableValue.
        description ?? value.map(CDP.displayString) ?? unserializableValue ?? "0"
    }

    private var objectTokens: [JSToken] {
        if subtype == "null" { return [JSToken("null", .null)] }
        if subtype == "error" {
            let message = description?.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Error"
            return [JSToken(message, .plain)]
        }
        if let preview { return Self.previewTokens(preview) }
        if let description, description != "Object" { return [JSToken(description, .className)] }
        return [JSToken(className ?? "Object", .className)]
    }

    /// "function adder(a0, a1) { [bytecode] }" → "ƒ adder(a0, a1)".
    static func functionSummary(_ description: String?) -> String {
        guard let description, !description.isEmpty else { return "ƒ ()" }
        let head = description.split(separator: "{", maxSplits: 1).first.map(String.init) ?? description
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("function ") ? String(trimmed.dropFirst("function ".count)) : trimmed
        return body.isEmpty ? "ƒ ()" : "ƒ \(body)"
    }

    static func previewTokens(_ preview: ObjectPreview) -> [JSToken] {
        if preview.subtype == "array" || preview.description?.hasPrefix("Array(") == true {
            var tokens = [JSToken("[", .punctuation)]
            for (index, property) in preview.properties.enumerated() {
                if index > 0 { tokens.append(JSToken(", ", .punctuation)) }
                tokens.append(elementToken(property))
            }
            if preview.overflow { tokens.append(JSToken(", …", .punctuation)) }
            tokens.append(JSToken("]", .punctuation))
            return tokens
        }
        if preview.subtype == "error" {
            return [JSToken(preview.description ?? "Error", .plain)]
        }
        var tokens: [JSToken] = []
        let className = preview.description ?? ""
        if !className.isEmpty, className != "Object" { tokens.append(JSToken("\(className) ", .className)) }
        tokens.append(JSToken("{", .punctuation))
        for (index, property) in preview.properties.enumerated() {
            if index > 0 { tokens.append(JSToken(", ", .punctuation)) }
            tokens.append(JSToken(property.name, .key))
            tokens.append(JSToken(": ", .punctuation))
            tokens.append(elementToken(property))
        }
        if preview.overflow { tokens.append(JSToken(", …", .punctuation)) }
        tokens.append(JSToken("}", .punctuation))
        return tokens
    }

    private static func elementToken(_ property: PropertyPreview) -> JSToken {
        switch property.type {
        case "string": JSToken("\"\(property.value ?? "")\"", .string)
        case "number", "bigint": JSToken(property.value ?? "", .number)
        case "boolean": JSToken(property.value ?? "", .boolean)
        case "undefined": JSToken("undefined", .undefined)
        case "symbol": JSToken(property.value ?? "Symbol()", .symbol)
        case "function": JSToken("ƒ", .function)
        case "object":
            property.subtype == "null"
                ? JSToken("null", .null)
                : JSToken(property.value ?? "Object", .className)
        default: JSToken(property.value ?? "", .plain)
        }
    }
}

public extension CDP {
    /// Plain rendering of a decoded JSON value (for primitives carried in
    /// `RemoteObject.value`). Guards against `Int(NaN/Infinity)`.
    static func displayString(_ value: JSONValue) -> String {
        switch value {
        case let .number(number):
            return (number.isFinite && number == number.rounded()) ? String(Int(number)) : String(number)
        case let .bool(flag): return String(flag)
        case let .string(text): return text
        case .null: return "null"
        default: return value.jsonString
        }
    }
}
