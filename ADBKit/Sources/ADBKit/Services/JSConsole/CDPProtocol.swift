import Foundation

/// Chrome DevTools Protocol message framing and typed decoders for the bits a
/// JavaScript console needs: `Runtime.evaluate`, `Runtime.getProperties`, and
/// the `Runtime.consoleAPICalled` / `Runtime.exceptionThrown` events. All pure
/// and `Sendable` — the request builders and decoders are unit-tested with
/// recorded payloads, no socket required. The transport lives in
/// `JSConsoleClient`.
public enum CDP {
    // MARK: - Outbound requests

    /// A `{ id, method, params }` request envelope.
    public static func request(id: Int, method: String, params: [String: JSONValue]) -> JSONValue {
        .object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(params),
        ])
    }

    /// REPL-flavored `Runtime.evaluate` params. `replMode` allows `let`
    /// re-declaration and top-level `await`; `includeCommandLineAPI` exposes
    /// `$_` and friends; `generatePreview` returns inline object previews so the
    /// common log line renders without a follow-up `getProperties`; the object
    /// is kept in the `console` group (not returned by value) so it can be
    /// expanded lazily and released together on clear.
    public static func evaluateParams(expression: String) -> [String: JSONValue] {
        [
            "expression": .string(expression),
            "objectGroup": .string("console"),
            "includeCommandLineAPI": .bool(true),
            "replMode": .bool(true),
            "generatePreview": .bool(true),
            "userGesture": .bool(true),
            "awaitPromise": .bool(true),
            "returnByValue": .bool(false),
        ]
    }

    public static func getPropertiesParams(objectId: String) -> [String: JSONValue] {
        [
            "objectId": .string(objectId),
            "ownProperties": .bool(true),
            "generatePreview": .bool(true),
        ]
    }

    public static func releaseObjectGroupParams(_ group: String) -> [String: JSONValue] {
        ["objectGroup": .string(group)]
    }

    public static func callFunctionOnParams(objectId: String, functionDeclaration: String) -> [String: JSONValue] {
        [
            "objectId": .string(objectId),
            "functionDeclaration": .string(functionDeclaration),
            "returnByValue": .bool(true),
            "awaitPromise": .bool(true),
        ]
    }

    /// Runs in the device's JS context (via `callFunctionOn`, `this` = the object)
    /// to produce a faithful deep JSON string for "Copy as JSON" — handling the
    /// types `JSON.stringify` drops or chokes on (bigint, functions, symbols,
    /// Map/Set, RegExp) and circular references. Dates serialize to ISO via their
    /// own `toJSON`.
    public static let deepStringifyFunction = """
    function () {
      const seen = new WeakSet();
      const replacer = (key, value) => {
        if (typeof value === 'bigint') return value.toString() + 'n';
        if (typeof value === 'number' && !Number.isFinite(value)) {
          return value > 0 ? 'Infinity' : value < 0 ? '-Infinity' : 'NaN';
        }
        if (Object.is(value, -0)) return '-0';
        if (typeof value === 'undefined') return '[undefined]';
        if (typeof value === 'function') return '[Function ' + (value.name || 'anonymous') + ']';
        if (typeof value === 'symbol') return value.toString();
        if (value instanceof Error) return { name: value.name, message: value.message, stack: value.stack };
        if (value instanceof Map) return { dataType: 'Map', entries: Array.from(value.entries()) };
        if (value instanceof Set) return { dataType: 'Set', values: Array.from(value.values()) };
        if (value instanceof RegExp) return value.toString();
        if (value && typeof value === 'object') {
          if (seen.has(value)) return '[Circular]';
          seen.add(value);
        }
        return value;
      };
      try { return JSON.stringify(this, replacer, 2); } catch (e) { return String(this); }
    }
    """

    // MARK: - Inbound messages

    /// A decoded inbound frame: either a reply to one of our requests (`id`) or
    /// an unsolicited event (`method`).
    public enum Incoming: Sendable, Equatable {
        case response(id: Int, result: JSONValue?, error: CDPError?)
        case event(method: String, params: JSONValue)
    }

    public static func parseIncoming(_ data: Data) -> Incoming? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        if let id = root["id"]?.intValue {
            return .response(id: id, result: root["result"], error: CDPError(json: root["error"]))
        }
        if let method = root["method"]?.stringValue {
            return .event(method: method, params: root["params"] ?? .object([:]))
        }
        return nil
    }
}

/// A protocol-level error (`{ code, message }`) — distinct from a JavaScript
/// exception, which arrives as `exceptionDetails` inside a successful reply.
public struct CDPError: Sendable, Equatable {
    public let code: Int
    public let message: String

    public init?(json: JSONValue?) {
        guard let json, let message = json["message"]?.stringValue else { return nil }
        code = json["code"]?.intValue ?? 0
        self.message = message
    }
}

/// A CDP `Runtime.RemoteObject` — a reference to (or value of) a JS value. For
/// objects/functions, `objectId` is the handle passed to `Runtime.getProperties`
/// to expand it; `preview` is the inline collapsed rendering.
public struct RemoteObject: Sendable, Equatable {
    public let type: String
    public let subtype: String?
    public let className: String?
    public let value: JSONValue?
    public let unserializableValue: String?
    public let description: String?
    public let objectId: String?
    public let preview: ObjectPreview?

    public init(json: JSONValue) {
        type = json["type"]?.stringValue ?? "undefined"
        subtype = json["subtype"]?.stringValue
        className = json["className"]?.stringValue
        value = json["value"]
        unserializableValue = json["unserializableValue"]?.stringValue
        description = json["description"]?.stringValue
        objectId = json["objectId"]?.stringValue
        preview = json["preview"].map(ObjectPreview.init(json:))
    }

    /// Has a handle that can be expanded with `getProperties`.
    public var isExpandable: Bool {
        objectId != nil && (type == "object" || type == "function") && subtype != "null"
    }
}

/// A collapsed inline preview of an object/array (CDP `ObjectPreview`).
public struct ObjectPreview: Sendable, Equatable {
    public let type: String
    public let subtype: String?
    public let description: String?
    public let overflow: Bool
    public let properties: [PropertyPreview]

    public init(json: JSONValue) {
        type = json["type"]?.stringValue ?? "object"
        subtype = json["subtype"]?.stringValue
        description = json["description"]?.stringValue
        overflow = json["overflow"]?.boolValue ?? false
        properties = (json["properties"]?.arrayValue ?? []).map(PropertyPreview.init(json:))
    }
}

public struct PropertyPreview: Sendable, Equatable {
    public let name: String
    public let type: String
    public let value: String?
    public let subtype: String?

    public init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        type = json["type"]?.stringValue ?? "string"
        value = json["value"]?.stringValue
        subtype = json["subtype"]?.stringValue
    }
}

/// One own property from `Runtime.getProperties` — the rows shown when an object
/// is expanded.
public struct CDPProperty: Sendable, Equatable, Identifiable {
    public let name: String
    public let value: RemoteObject?

    public var id: String { name }

    /// Parse the `result` array of a `getProperties` reply, keeping enumerable
    /// own data properties (skipping pure getters/setters with no value) so the
    /// expanded view shows the same fields a developer expects.
    public static func parse(_ result: JSONValue?) -> [CDPProperty] {
        guard let array = result?["result"]?.arrayValue else { return [] }
        return array.compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            guard let value = entry["value"] else { return nil }
            return CDPProperty(name: name, value: RemoteObject(json: value))
        }
    }
}

/// A `Runtime.consoleAPICalled` event — one `console.*` call from the app.
public struct ConsoleAPICall: Sendable, Equatable {
    public let type: String
    public let args: [RemoteObject]
    public let timestamp: Double?
    public let stackTrace: CDPStackTrace?

    public init(params: JSONValue) {
        type = params["type"]?.stringValue ?? "log"
        args = (params["args"]?.arrayValue ?? []).map(RemoteObject.init(json:))
        timestamp = params["timestamp"]?.doubleValue
        stackTrace = params["stackTrace"].map(CDPStackTrace.init(json:))
    }
}

/// Details of a thrown JS error, from `Runtime.exceptionThrown` or the
/// `exceptionDetails` of a `Runtime.evaluate` reply.
public struct ExceptionDetails: Sendable, Equatable {
    public let text: String
    public let exception: RemoteObject?
    public let lineNumber: Int?
    public let columnNumber: Int?
    public let url: String?
    public let stackTrace: CDPStackTrace?

    public init(json: JSONValue) {
        text = json["text"]?.stringValue ?? "Uncaught"
        exception = json["exception"].map(RemoteObject.init(json:))
        lineNumber = json["lineNumber"]?.intValue
        columnNumber = json["columnNumber"]?.intValue
        url = json["url"]?.stringValue
        stackTrace = json["stackTrace"].map(CDPStackTrace.init(json:))
    }

    /// The error's full message (and embedded stack, for an Error object) — what
    /// to render as the failure line.
    public var message: String {
        exception?.description ?? text
    }
}

public struct CDPStackTrace: Sendable, Equatable {
    public let callFrames: [CDPCallFrame]

    public init(json: JSONValue) {
        callFrames = (json["callFrames"]?.arrayValue ?? []).map(CDPCallFrame.init(json:))
    }
}

public struct CDPCallFrame: Sendable, Equatable, Identifiable {
    public let functionName: String
    public let url: String
    public let lineNumber: Int
    public let columnNumber: Int

    public var id: String { "\(functionName)@\(url):\(lineNumber):\(columnNumber)" }

    public init(json: JSONValue) {
        functionName = json["functionName"]?.stringValue ?? ""
        url = json["url"]?.stringValue ?? ""
        lineNumber = json["lineNumber"]?.intValue ?? 0
        columnNumber = json["columnNumber"]?.intValue ?? 0
    }

    /// `functionName  file:line` — CDP line numbers are 0-based, shown 1-based.
    public var display: String {
        let fn = functionName.isEmpty ? "(anonymous)" : functionName
        guard !url.isEmpty else { return fn }
        return "\(fn)  \(url):\(lineNumber + 1)"
    }
}

/// The outcome of a `Runtime.evaluate`: a value, or a JavaScript exception. A
/// thrown JS error comes back in the *successful* reply as `exceptionDetails`,
/// so this never collapses a JS throw into a transport error.
public enum EvalOutcome: Sendable, Equatable {
    case value(RemoteObject)
    case error(ExceptionDetails)

    public static func from(result: JSONValue?) -> EvalOutcome {
        if let details = result?["exceptionDetails"] {
            return .error(ExceptionDetails(json: details))
        }
        let object = result?["result"] ?? .object(["type": .string("undefined")])
        return .value(RemoteObject(json: object))
    }
}
