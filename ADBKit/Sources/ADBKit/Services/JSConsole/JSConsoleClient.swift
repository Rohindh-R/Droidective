import Foundation

/// A Chrome DevTools Protocol client over a single WebSocket — the transport for
/// the JS console. Connects to a target's `webSocketDebuggerUrl` (handed out by
/// `MetroInspector`), enables the `Runtime`/`Log` domains, evaluates
/// expressions, expands objects, and streams console + exception events.
///
/// Built on `URLSessionWebSocketTask` (Foundation — no dependency). The actor
/// owns the non-`Sendable` task and never lets it escape: every touch happens in
/// actor-isolated code. Request/response correlation is by integer `id`; a tiny
/// early-result buffer closes the window where a reply could land between
/// sending a request and registering its continuation.
public actor JSConsoleClient {
    public enum ClientError: Error, Sendable, LocalizedError {
        case notConnected
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to a JavaScript target."
            case let .transport(detail): detail
            }
        }
    }

    /// Events streamed to the session as they arrive.
    public enum Event: Sendable {
        case console(ConsoleAPICall)
        case exception(ExceptionDetails)
        case contextCreated(id: Int)
        case contextDestroyed
        case closed(reason: String)
    }

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var pending: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    private var earlyResults: [Int: Result<JSONValue?, Error>] = [:]
    private var nextId = 1

    public init() {}

    public var isConnected: Bool { task != nil }

    /// The WebSocket upgrade request for a debugger target. The React Native
    /// (Fusebox) inspector proxy rejects the connection with HTTP 401 unless the
    /// `Origin` header is the dev-server origin or a loopback hostname
    /// (`localhost` / `127.0.0.1` / `0.0.0.0`), so set it to `localhost` on the
    /// target's port — that satisfies the proxy's allowlist for every loopback
    /// form, and Hermes ignores the header on older React Native.
    public nonisolated static func debuggerRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("http://localhost:\(url.port ?? 8081)", forHTTPHeaderField: "Origin")
        return request
    }

    /// Open the WebSocket and enable the domains a console needs. Returns the
    /// event stream; it finishes when the connection closes or `disconnect()` is
    /// called. Re-entrant: a previous connection is torn down first. Throws if
    /// the connection can't be established (so the caller can retry), detected
    /// via `Runtime.enable` — `Log.enable` is best-effort for older peers.
    public func connect(to url: URL) async throws -> AsyncStream<Event> {
        teardown(reason: "reconnecting")
        let task = URLSession.shared.webSocketTask(with: Self.debuggerRequest(for: url))
        self.task = task
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation
        task.resume()
        startReceiveLoop()
        startHeartbeat()
        do {
            _ = try await send(method: "Runtime.enable", params: [:])
        } catch {
            teardown(reason: "connect failed")
            throw error
        }
        _ = try? await send(method: "Log.enable", params: [:])
        return stream
    }

    public func evaluate(_ expression: String) async throws -> EvalOutcome {
        let result = try await send(method: "Runtime.evaluate", params: CDP.evaluateParams(expression: expression))
        return EvalOutcome.from(result: result)
    }

    public func getProperties(objectId: String) async throws -> [CDPProperty] {
        let result = try await send(method: "Runtime.getProperties", params: CDP.getPropertiesParams(objectId: objectId))
        return CDPProperty.parse(result)
    }

    /// A faithful deep-JSON rendering of an object, evaluated in the runtime via
    /// `callFunctionOn` — for "Copy as JSON". Returns nil on transport failure.
    public func deepStringify(objectId: String) async -> String? {
        let result = try? await send(
            method: "Runtime.callFunctionOn",
            params: CDP.callFunctionOnParams(objectId: objectId, functionDeclaration: CDP.deepStringifyFunction)
        )
        return result?["result"]?["value"]?.stringValue
    }

    /// Release the `console` object group — drops the device-side handles for
    /// everything evaluated/logged so far. Called when the console is cleared so
    /// remote objects don't accumulate. Best-effort.
    public func releaseConsoleObjects() async {
        _ = try? await send(method: "Runtime.releaseObjectGroup", params: CDP.releaseObjectGroupParams("console"))
    }

    public func disconnect() {
        teardown(reason: "disconnected")
    }

    // MARK: - Request / response

    private func send(method: String, params: [String: JSONValue]) async throws -> JSONValue? {
        guard let task else { throw ClientError.notConnected }
        let id = nextId
        nextId += 1
        let envelope = CDP.request(id: id, method: method, params: params)
        guard let data = try? JSONEncoder().encode(envelope) else {
            throw ClientError.transport("Couldn't encode \(method).")
        }
        // Send first, then register the continuation. The send's suspension
        // releases the actor, so the reply can arrive before we register — the
        // receive loop stashes it in `earlyResults` and we pick it up below.
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw ClientError.transport("\(error.localizedDescription)")
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let early = earlyResults.removeValue(forKey: id) {
                continuation.resume(with: early)
            } else if self.task != nil {
                pending[id] = continuation
            } else {
                // The socket closed during the send await (teardown/handleClosed
                // already drained `pending`), so nothing would ever resume this.
                continuation.resume(throwing: ClientError.notConnected)
            }
        }
    }

    private func resolve(id: Int, _ result: Result<JSONValue?, Error>) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(with: result)
        } else {
            earlyResults[id] = result
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task else { return }
            do {
                let message = try await task.receive()
                handle(message)
            } catch {
                handleClosed("\(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(payload): data = payload
        @unknown default: return
        }
        guard let incoming = CDP.parseIncoming(data) else { return }
        switch incoming {
        case let .response(id, result, error):
            if let error {
                resolve(id: id, .failure(ClientError.transport(error.message)))
            } else {
                resolve(id: id, .success(result))
            }
        case let .event(method, params):
            emit(method: method, params: params)
        }
    }

    private func emit(method: String, params: JSONValue) {
        switch method {
        case "Runtime.consoleAPICalled":
            continuation?.yield(.console(ConsoleAPICall(params: params)))
        case "Runtime.exceptionThrown":
            if let details = params["exceptionDetails"] {
                continuation?.yield(.exception(ExceptionDetails(json: details)))
            }
        case "Runtime.executionContextCreated":
            if let id = params["context"]?["id"]?.intValue {
                continuation?.yield(.contextCreated(id: id))
            }
        case "Runtime.executionContextDestroyed":
            continuation?.yield(.contextDestroyed)
        default:
            break
        }
    }

    private func handleClosed(_ reason: String) {
        guard continuation != nil else { return }
        cancelTasks()
        task = nil
        failPending(ClientError.transport(reason))
        continuation?.yield(.closed(reason: reason))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Heartbeat

    /// The Metro inspector proxy pings on an interval and drops a peer that
    /// doesn't pong; `URLSessionWebSocketTask` doesn't reliably reply on its own,
    /// so send our own ping under that window to hold the connection open.
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                await self?.ping()
            }
        }
    }

    private func ping() {
        task?.sendPing { _ in }
    }

    // MARK: - Teardown

    private func cancelTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func teardown(reason: String) {
        cancelTasks()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(ClientError.notConnected)
        continuation?.finish()
        continuation = nil
    }

    private func failPending(_ error: Error) {
        let waiting = pending.values
        pending.removeAll()
        earlyResults.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }
}
