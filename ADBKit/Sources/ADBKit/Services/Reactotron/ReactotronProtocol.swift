import Foundation

/// Reactotron wire command types — mirrors `reactotron-core-contract`'s
/// `CommandType`. We decode the frames a client sends; unrecognized strings fall
/// through to `ReactotronEvent.unknown`.
public enum ReactotronCommandType: String, Sendable {
    case clientIntro = "client.intro"
    case log
    case display
    case image
    case apiResponse = "api.response"
    case benchmark = "benchmark.report"
    case clear
    case asyncStorageMutation = "asyncStorage.mutation"
    case stateActionComplete = "state.action.complete"
    case stateValuesChange = "state.values.change"
    case stateValuesResponse = "state.values.response"
    case stateKeysResponse = "state.keys.response"
    case stateBackupResponse = "state.backup.response"
    case customCommandRegister = "customCommand.register"
    case customCommandUnregister = "customCommand.unregister"
    case sagaTaskComplete = "saga.task.complete"
    case replLsResponse = "repl.ls.response"
    case replExecuteResponse = "repl.execute.response"
    case devtoolsOpen = "devtools.open"
    case devtoolsReload = "devtools.reload"
    case editorOpen = "editor.open"
    case storybook
    case overlay
}

/// A raw command frame received from a Reactotron client. The envelope is fixed;
/// `payload` stays type-erased because its shape depends on `type`. `payload` is
/// optional because some commands (e.g. `clear`) carry none.
public struct ReactotronCommand: Sendable, Equatable, Codable {
    public let type: String
    public let payload: JSONValue?
    public let important: Bool?
    public let date: String?
    public let deltaTime: Double?

    public init(
        type: String,
        payload: JSONValue? = nil,
        important: Bool? = nil,
        date: String? = nil,
        deltaTime: Double? = nil
    ) {
        self.type = type
        self.payload = payload
        self.important = important
        self.date = date
        self.deltaTime = deltaTime
    }

    /// Lenient decode: the reactotron client serializes some values as
    /// `"~~~ … ~~~"` string markers (functions, and even booleans — `important`
    /// arrives as `"~~~ false ~~~"`). Extracting fields from a `JSONValue`
    /// instead of strict typed keys means a marker never fails the whole frame.
    public init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)
        type = root["type"]?.stringValue ?? ""
        payload = root["payload"]
        important = ReactotronCommand.lenientBool(root["important"])
        date = root["date"]?.stringValue
        deltaTime = root["deltaTime"]?.doubleValue
    }

    private static func lenientBool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if let bool = value.boolValue { return bool }
        if let text = value.stringValue { return text.contains("true") }
        return nil
    }

    public var isImportant: Bool { important ?? false }
    public var commandType: ReactotronCommandType? { ReactotronCommandType(rawValue: type) }

    public static func decode(_ data: Data) throws -> ReactotronCommand {
        try JSONDecoder().decode(ReactotronCommand.self, from: data)
    }

    public static func decode(_ text: String) throws -> ReactotronCommand {
        try decode(Data(text.utf8))
    }
}

public enum ReactotronLogLevel: String, Sendable, Equatable {
    case debug
    case warn
    case error
}

public struct ReactotronStackFrame: Sendable, Equatable {
    public let fileName: String
    public let functionName: String
    public let lineNumber: Int?
    public let columnNumber: Int?

    public init(fileName: String, functionName: String, lineNumber: Int?, columnNumber: Int?) {
        self.fileName = fileName
        self.functionName = functionName
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
    }
}

public struct ReactotronBenchmarkStep: Sendable, Equatable {
    public let title: String
    public let time: Double
    public let delta: Double

    public init(title: String, time: Double, delta: Double) {
        self.title = title
        self.time = time
        self.delta = delta
    }
}

public struct ReactotronStateChange: Sendable, Equatable {
    public let path: String
    public let value: JSONValue

    public init(path: String, value: JSONValue) {
        self.path = path
        self.value = value
    }
}

public struct ReactotronCommandArg: Sendable, Equatable {
    public let name: String
    /// In practice always "string"; the contract leaves it open.
    public let type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// A decoded, typed timeline item — what the UI renders. Built from a
/// `ReactotronCommand`; forward-compatible types land in `.unknown`.
public enum ReactotronEvent: Sendable, Equatable {
    case clientIntro(name: String, environment: String?, platform: String?, clientVersion: String?)
    case log(level: ReactotronLogLevel, message: String, stack: [ReactotronStackFrame])
    case display(name: String, value: JSONValue?, preview: String?, image: String?)
    case image(uri: String, preview: String?, caption: String?, width: Double?, height: Double?)
    case apiResponse(method: String, url: String, status: Int, duration: Double, request: JSONValue?, response: JSONValue?)
    case benchmark(title: String, steps: [ReactotronBenchmarkStep])
    case clear
    case asyncStorage(action: String, data: JSONValue?)
    case stateAction(name: String, action: JSONValue?, ms: Double?)
    case stateValuesChange(changes: [ReactotronStateChange])
    case customCommandRegister(id: Int, command: String, title: String?, description: String?, args: [ReactotronCommandArg])
    case customCommandUnregister(id: Int, command: String)
    /// `state.values.response`. A null/empty path means the client returned the
    /// *whole* store in `value` (how a full state tree arrives from MST via
    /// `state.values.request`); otherwise it's the value at that one path.
    case stateValuesResponse(path: String?, value: JSONValue?)
    /// `state.keys.response`. With a path, `keys` is the array of key names at that
    /// path; with a null path the client returns the *whole* cleaned store in
    /// `keys` — which is how a full state tree arrives via `state.values.request`.
    case stateKeysResponse(path: String?, keys: JSONValue?)
    case stateBackup(state: JSONValue?)
    case replKeys([String])
    case replResult(JSONValue?)
    case unknown(type: String, payload: JSONValue?)
}

public extension ReactotronEvent {
    /// Parse a raw frame into a typed timeline event.
    init(command: ReactotronCommand) {
        let payload = command.payload
        guard let type = command.commandType else {
            self = .unknown(type: command.type, payload: payload)
            return
        }
        switch type {
        case .clientIntro:
            self = .clientIntro(
                name: payload?["name"]?.stringValue ?? "App",
                environment: payload?["environment"]?.stringValue,
                platform: payload?["platform"]?.stringValue,
                clientVersion: payload?["reactotronCoreClientVersion"]?.stringValue
                    ?? payload?["reactotronVersion"]?.stringValue
            )
        case .log:
            let level = ReactotronLogLevel(rawValue: payload?["level"]?.stringValue ?? "debug") ?? .debug
            self = .log(
                level: level,
                message: Self.messageText(payload?["message"]),
                stack: Self.parseStack(payload?["stack"])
            )
        case .display:
            self = .display(
                name: payload?["name"]?.stringValue ?? "Display",
                value: payload?["value"],
                preview: payload?["preview"]?.stringValue,
                image: Self.imageURI(payload?["image"])
            )
        case .image:
            self = .image(
                uri: payload?["uri"]?.stringValue ?? "",
                preview: payload?["preview"]?.stringValue,
                caption: payload?["caption"]?.stringValue,
                width: payload?["width"]?.doubleValue,
                height: payload?["height"]?.doubleValue
            )
        case .apiResponse:
            let request = payload?["request"]
            let response = payload?["response"]
            self = .apiResponse(
                method: (request?["method"]?.stringValue ?? "GET").uppercased(),
                url: request?["url"]?.stringValue ?? "",
                status: response?["status"]?.intValue ?? 0,
                duration: payload?["duration"]?.doubleValue ?? 0,
                request: request,
                response: response
            )
        case .benchmark:
            let steps = (payload?["steps"]?.arrayValue ?? []).map { step in
                ReactotronBenchmarkStep(
                    title: step["title"]?.stringValue ?? "",
                    time: step["time"]?.doubleValue ?? 0,
                    delta: step["delta"]?.doubleValue ?? 0
                )
            }
            self = .benchmark(title: payload?["title"]?.stringValue ?? "Benchmark", steps: steps)
        case .clear:
            self = .clear
        case .asyncStorageMutation:
            self = .asyncStorage(
                action: payload?["action"]?.stringValue ?? "",
                data: payload?["data"]
            )
        case .stateActionComplete:
            self = .stateAction(
                name: payload?["name"]?.stringValue ?? "(action)",
                action: payload?["action"],
                ms: payload?["ms"]?.doubleValue
            )
        case .stateValuesChange:
            let changes = (payload?["changes"]?.arrayValue ?? []).map { change in
                ReactotronStateChange(
                    path: change["path"]?.stringValue ?? "",
                    value: change["value"] ?? .null
                )
            }
            self = .stateValuesChange(changes: changes)
        case .customCommandRegister:
            let args = (payload?["args"]?.arrayValue ?? []).map { arg in
                ReactotronCommandArg(
                    name: arg["name"]?.stringValue ?? "",
                    type: arg["type"]?.stringValue ?? "string"
                )
            }
            self = .customCommandRegister(
                id: payload?["id"]?.intValue ?? 0,
                command: payload?["command"]?.stringValue ?? "",
                title: payload?["title"]?.stringValue,
                description: payload?["description"]?.stringValue,
                args: args
            )
        case .customCommandUnregister:
            self = .customCommandUnregister(
                id: payload?["id"]?.intValue ?? 0,
                command: payload?["command"]?.stringValue ?? ""
            )
        case .stateValuesResponse:
            self = .stateValuesResponse(path: payload?["path"]?.stringValue, value: payload?["value"])
        case .stateKeysResponse:
            self = .stateKeysResponse(path: payload?["path"]?.stringValue, keys: payload?["keys"])
        case .stateBackupResponse:
            self = .stateBackup(state: payload?["state"])
        case .replLsResponse:
            self = .replKeys((payload?.arrayValue ?? []).compactMap { $0.stringValue })
        case .replExecuteResponse:
            self = .replResult(payload)
        case .sagaTaskComplete,
             .devtoolsOpen, .devtoolsReload, .editorOpen, .storybook, .overlay:
            self = .unknown(type: command.type, payload: payload)
        }
    }

    private static func messageText(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case let .string(text): return String(text.prefix(500))
        case let .object(dict): return "{ \(dict.count) }"
        case let .array(items): return "[ \(items.count) ]"
        case let .number(number):
            return number.truncatingRemainder(dividingBy: 1) == 0 && abs(number) < 9e15
                ? String(Int(number)) : String(number)
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func imageURI(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text }
        return value["uri"]?.stringValue
    }

    private static func parseStack(_ value: JSONValue?) -> [ReactotronStackFrame] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { frame in
            if let object = frame.objectValue {
                return ReactotronStackFrame(
                    fileName: object["fileName"]?.stringValue ?? "",
                    functionName: object["functionName"]?.stringValue ?? "",
                    lineNumber: object["lineNumber"]?.intValue,
                    columnNumber: object["columnNumber"]?.intValue
                )
            }
            if let text = frame.stringValue {
                return ReactotronStackFrame(
                    fileName: text, functionName: "", lineNumber: nil, columnNumber: nil
                )
            }
            return nil
        }
    }
}
