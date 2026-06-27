import Foundation
import Network

/// A Reactotron-compatible WebSocket server. The RN app (running
/// `reactotron-react-native`) is the client; this is the server it connects to
/// on port 9090. Speaks Reactotron's JSON-over-WebSocket protocol from Swift.
///
/// This is the inbound mirror of `MirrorTransport`: where that opens an outbound
/// `NWConnection`, this runs an `NWListener` with `NWProtocolWebSocket` and
/// accepts client sockets. The Swift-6 mechanics are the same — box the
/// non-`Sendable` `NWConnection` to cross into the framework's `@Sendable`
/// callbacks, run everything on one serial queue, and hop back onto the actor to
/// touch state.
public actor ReactotronServer {
    public enum ServerError: Error, Sendable, LocalizedError {
        case invalidPort(UInt16)
        case startFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidPort(port): "Invalid port \(port)."
            case let .startFailed(detail): "Reactotron server failed to start: \(detail)"
            }
        }
    }

    /// Events surfaced to the UI as the server runs.
    public enum Event: Sendable {
        case listening(port: UInt16)
        case connected(connectionId: Int, intro: ReactotronCommand)
        case command(connectionId: Int, command: ReactotronCommand)
        case disconnected(connectionId: Int)
        case failed(reason: String, portInUse: Bool)
    }

    /// `NWConnection` isn't `Sendable`; it's only touched on the serial queue or
    /// while owned by this actor, so box it to cross into `@Sendable` callbacks.
    struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    private static let queue = DispatchQueue(label: "com.rohindh.droidective.reactotron-server")

    private let port: UInt16
    private var listener: NWListener?
    private var connections: [Int: ConnectionBox] = [:]
    private var nextConnectionId = 1
    private var continuation: AsyncStream<Event>.Continuation?

    public init(port: UInt16 = 9090) {
        self.port = port
    }

    /// The port the listener actually bound to (useful when constructed with
    /// port 0 to get an OS-assigned port, e.g. in tests). Nil until ready.
    public var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Start listening. The stream finishes when `stop()` is called or the
    /// listener fails. Restarting stops any previous listener first.
    public func start() throws -> AsyncStream<Event> {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        // Bind to loopback only. The device reaches the server through
        // `adb reverse tcp:9090` (forwarded over loopback), so this is
        // transparent — and it keeps the debug server off the LAN, where it
        // would otherwise accept unauthenticated connections from anyone.
        parameters.requiredInterfaceType = .loopback
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw ServerError.startFailed("\(error)")
        }
        self.listener = listener

        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.listenerBecameReady() }
            case let .failed(error):
                Task { await self.failListener(error) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let box = ConnectionBox(connection: connection)
            Task { await self.accept(box) }
        }
        listener.start(queue: Self.queue)
        return stream
    }

    /// Tear down the listener and all client sockets. Safe to call repeatedly.
    public func stop() {
        for box in connections.values {
            box.connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Listener lifecycle

    private func listenerBecameReady() {
        guard let port = listener?.port?.rawValue else { return }
        continuation?.yield(.listening(port: port))
    }

    private func failListener(_ error: NWError) {
        var portInUse = false
        if case let .posix(code) = error, code == .EADDRINUSE {
            portInUse = true
        }
        continuation?.yield(.failed(reason: "\(error)", portInUse: portInUse))
        stop()
    }

    // MARK: - Connections

    private func accept(_ box: ConnectionBox) {
        let id = nextConnectionId
        nextConnectionId += 1
        connections[id] = box

        box.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.dropConnection(id) }
            default:
                break
            }
        }
        box.connection.start(queue: Self.queue)
        Self.receiveLoop(box, id: id, server: self)
    }

    private func dropConnection(_ id: Int) {
        guard let box = connections.removeValue(forKey: id) else { return }
        box.connection.cancel()
        continuation?.yield(.disconnected(connectionId: id))
    }

    /// Recursive receive loop, off the actor (like `MirrorTransport.receiveLoop`).
    /// Each WebSocket text frame is one Reactotron command; hop onto the actor to
    /// decode and deliver it, then continue receiving.
    private nonisolated static func receiveLoop(_ box: ConnectionBox, id: Int, server: ReactotronServer) {
        box.connection.receiveMessage { content, context, _, error in
            if let context,
               let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
               as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    if let content {
                        Task { await server.handleFrame(connectionId: id, data: content) }
                    }
                case .close:
                    Task { await server.dropConnection(id) }
                    return
                default:
                    break
                }
            }
            if error != nil {
                Task { await server.dropConnection(id) }
                return
            }
            receiveLoop(box, id: id, server: server)
        }
    }

    private func handleFrame(connectionId id: Int, data: Data) {
        guard let command = try? ReactotronCommand.decode(data) else {
            let raw = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            continuation?.yield(.command(
                connectionId: id,
                command: ReactotronCommand(type: "(undecodable)", payload: .string(String(raw.prefix(300))))
            ))
            return
        }
        if command.commandType == .clientIntro {
            completeHandshake(connectionId: id, intro: command)
            continuation?.yield(.connected(connectionId: id, intro: command))
        } else {
            continuation?.yield(.command(connectionId: id, command: command))
        }
    }

    // MARK: - Handshake

    /// On `client.intro`: assign a clientId if the client has none, then send the
    /// (empty) subscription list to complete the handshake — exactly what
    /// `reactotron-core-server` does.
    private func completeHandshake(connectionId id: Int, intro: ReactotronCommand) {
        guard let box = connections[id] else { return }
        let clientId = intro.payload?["clientId"]?.stringValue
        if clientId == nil || clientId?.isEmpty == true {
            send(type: "setClientId", payload: .string(UUID().uuidString), to: box)
        }
        send(type: "state.values.subscribe", payload: .object(["paths": .array([])]), to: box)
    }

    // MARK: - Server → client

    /// Send a frame to one connection (no-op if it has gone away).
    public func send(type: String, payload: JSONValue, toConnection id: Int) {
        guard let box = connections[id] else { return }
        send(type: type, payload: payload, to: box)
    }

    /// Send a frame to every connected client.
    public func broadcast(type: String, payload: JSONValue) {
        for box in connections.values {
            send(type: type, payload: payload, to: box)
        }
    }

    /// Send one server→client frame: `{ type, payload }` as a WebSocket text frame.
    private func send(type: String, payload: JSONValue, to box: ConnectionBox) {
        let envelope = JSONValue.object(["type": .string(type), "payload": payload])
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        box.connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}
