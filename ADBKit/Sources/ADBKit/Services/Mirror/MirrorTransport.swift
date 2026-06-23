import Foundation
import Network

/// Brings up a scrcpy mirroring session's plumbing and streams the raw video
/// socket bytes.
///
/// Reuses scrcpy's device-side server but speaks its protocol from Swift: push
/// the server, open a forward tunnel (`adb forward tcp:0 …` so adb picks a free
/// port — avoids collisions with a stock scrcpy or a second app instance), start
/// the server (it listens on the local abstract socket), then connect and pump
/// bytes. Feed the byte stream into a `ScrcpyStreamDecoder`. `stop()` tears the
/// whole thing down and is idempotent.
///
/// This is ADBKit's first long-lived/streaming exec path, so it manages a
/// `Process` and an `NWConnection` directly rather than going through the
/// finite-output `ProcessRunning` seam.
public actor MirrorTransport {
    public struct Configuration: Sendable {
        public var serial: String
        public var params: ScrcpyServerParams
        public var serverVersion: String
        public var localJarPath: String
        public var remoteJarPath: String

        public init(
            serial: String,
            params: ScrcpyServerParams,
            serverVersion: String,
            localJarPath: String,
            remoteJarPath: String = "/data/local/tmp/scrcpy-server.jar"
        ) {
            self.serial = serial
            self.params = params
            self.serverVersion = serverVersion
            self.localJarPath = localJarPath
            self.remoteJarPath = remoteJarPath
        }
    }

    public enum TransportError: Error, LocalizedError, Sendable {
        case adbNotFound
        case pushFailed(String)
        case forwardFailed(String)
        case serverFailedToStart(String)
        case connectFailed(String)

        public var errorDescription: String? {
            switch self {
            case .adbNotFound: "adb not found — the mirror needs it to connect."
            case let .pushFailed(detail): "Couldn't push scrcpy-server: \(detail)"
            case let .forwardFailed(detail): "Couldn't open the adb tunnel: \(detail)"
            case let .serverFailedToStart(detail): "scrcpy-server didn't start: \(detail)"
            case let .connectFailed(detail): "Couldn't connect to the device stream: \(detail)"
            }
        }
    }

    /// NWConnection isn't Sendable; it's only ever touched on its own serial
    /// queue or while owned by this actor, so box it to cross the boundary.
    private struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    private static let queue = DispatchQueue(label: "com.rohindh.droidective.mirror-transport")

    private let adb: AdbClient
    private let config: Configuration

    private var serverProcess: Process?
    private var connectionBox: ConnectionBox?
    private var controlBox: ConnectionBox?
    private var controlIncomingStream: AsyncStream<Data>?
    private var controlIncomingContinuation: AsyncStream<Data>.Continuation?
    private var forwardedPort: UInt16?
    private var serverLog = ""

    public init(adb: AdbClient, config: Configuration) {
        self.adb = adb
        self.config = config
    }

    /// Push the server, open the tunnel, start the server, connect the video
    /// socket, and return its byte stream. Throws if any step fails.
    public func start() async throws -> AsyncThrowingStream<Data, Error> {
        let adbPath = try await resolveAdbPath()
        try await pushServer()
        let port = try await openForward()
        try startServer(adbPath: adbPath)
        let (box, firstChunk) = try await connect(port: port)
        connectionBox = box
        // With control enabled the server expects a second connection on the same
        // socket (1st = video, 2nd = control). Open it before streaming.
        if config.params.control {
            let controlConnection = try await connectControl(port: port)
            controlBox = controlConnection
            startControlReceive(controlConnection)
        }
        return makeByteStream(box, firstChunk: firstChunk)
    }

    /// Tear everything down: cancel the socket, kill the server, remove the
    /// tunnel. Safe to call repeatedly.
    public func stop() async {
        connectionBox?.connection.cancel()
        connectionBox = nil
        controlBox?.connection.cancel()
        controlBox = nil
        controlIncomingContinuation?.finish()
        controlIncomingContinuation = nil
        controlIncomingStream = nil
        if let process = serverProcess, process.isRunning { process.terminate() }
        serverProcess = nil
        if let port = forwardedPort {
            _ = try? await adb.run(on: config.serial, ["forward", "--remove", "tcp:\(port)"])
            forwardedPort = nil
        }
    }

    // MARK: - Steps

    private func resolveAdbPath() async throws -> String {
        guard let path = await adb.locator.resolve(.adb) else { throw TransportError.adbNotFound }
        return path
    }

    private func pushServer() async throws {
        let result: AdbResult
        do {
            result = try await adb.run(
                on: config.serial,
                ["push", config.localJarPath, config.remoteJarPath],
                timeout: .seconds(60))
        } catch {
            throw TransportError.adbNotFound
        }
        guard result.succeeded else {
            throw TransportError.pushFailed(friendlyAdbError(result, fallback: "adb push failed"))
        }
    }

    /// `adb forward tcp:0 …` allocates a free local port and prints it.
    private func openForward() async throws -> UInt16 {
        let result: AdbResult
        do {
            result = try await adb.run(
                on: config.serial,
                ["forward", "tcp:0", "localabstract:\(config.params.socketName)"])
        } catch {
            throw TransportError.adbNotFound
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, let port = UInt16(text) else {
            throw TransportError.forwardFailed(friendlyAdbError(result, fallback: "adb forward failed"))
        }
        forwardedPort = port
        return port
    }

    private func startServer(adbPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", config.serial]
            + config.params.shellArguments(
                serverVersion: config.serverVersion, remoteJarPath: config.remoteJarPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.appendServerLog(text) }
        }
        do {
            try process.run()
        } catch {
            throw TransportError.serverFailedToStart(error.localizedDescription)
        }
        serverProcess = process
    }

    private func appendServerLog(_ text: String) {
        serverLog += text
        if serverLog.count > 8192 { serverLog = String(serverLog.suffix(8192)) }
    }

    /// Connect to the forwarded port, retrying until the server is listening or
    /// the deadline passes (the server takes ~1s to boot via app_process).
    ///
    /// `adb forward` accepts the local TCP connect immediately — even before the
    /// device-side server is listening — and then drops it (EOF). So reaching
    /// `.ready` isn't enough; we must read the first byte (scrcpy's forward-mode
    /// dummy `0x00`) to confirm the server is really there, and retry on an empty
    /// EOF. The first chunk is returned so the stream replays it to the decoder.
    private func connect(port: UInt16) async throws -> (ConnectionBox, Data) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.connectFailed("invalid port \(port)")
        }
        let host = NWEndpoint.Host("127.0.0.1")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var lastError = ""
        while clock.now < deadline {
            let connection = NWConnection(host: host, port: nwPort, using: .tcp)
            do {
                try await Self.waitUntilReady(connection)
                let firstChunk = try await Self.firstReceive(connection)
                return (ConnectionBox(connection: connection), firstChunk)
            } catch {
                connection.cancel()
                lastError = "\(error)"
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let detail = lastError.isEmpty ? "timed out" : lastError
        let suffix = serverLog.isEmpty ? "" : " | server: \(serverLog)"
        throw TransportError.connectFailed(detail + suffix)
    }

    /// Read the first chunk. An empty EOF means the device side never accepted
    /// (server not listening yet) — surfaced as an error so `connect` retries.
    private nonisolated static func firstReceive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: TransportError.connectFailed("device side not ready"))
                }
            }
        }
    }

    private nonisolated static func waitUntilReady(_ connection: NWConnection) async throws {
        let guardrail = ContinuationGuard()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guardrail.tryResume { cont.resume() }
                    case let .failed(error):
                        guardrail.tryResume { cont.resume(throwing: error) }
                    case .cancelled:
                        guardrail.tryResume { cont.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: MirrorTransport.queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Connect the control socket (the server's 2nd accepted connection). No
    /// dummy byte here — the control channel goes straight to the protocol.
    private func connectControl(port: UInt16) async throws -> ConnectionBox {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.connectFailed("invalid port \(port)")
        }
        let host = NWEndpoint.Host("127.0.0.1")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var lastError = ""
        while clock.now < deadline {
            let connection = NWConnection(host: host, port: nwPort, using: .tcp)
            do {
                try await Self.waitUntilReady(connection)
                return ConnectionBox(connection: connection)
            } catch {
                connection.cancel()
                lastError = "\(error)"
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        throw TransportError.connectFailed("control socket: \(lastError)")
    }

    /// A Sendable sink for control bytes, or nil if control isn't enabled.
    /// `NWConnection.send` preserves per-connection order, so callers can fire
    /// touch/key events synchronously and in sequence.
    public func controlSender() -> (@Sendable (Data) -> Void)? {
        guard let box = controlBox else { return nil }
        return { data in
            box.connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Bytes the device sends back over the control socket (clipboard, acks), or
    /// nil if control isn't enabled. Parse with `ScrcpyDeviceMessageDecoder`.
    public func controlIncoming() -> AsyncStream<Data>? { controlIncomingStream }

    private func startControlReceive(_ box: ConnectionBox) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        controlIncomingStream = stream
        controlIncomingContinuation = continuation
        Self.controlReceiveLoop(box, continuation)
    }

    private nonisolated static func controlReceiveLoop(
        _ box: ConnectionBox, _ continuation: AsyncStream<Data>.Continuation
    ) {
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            data, _, isComplete, error in
            if let data, !data.isEmpty { continuation.yield(data) }
            if error != nil || isComplete {
                continuation.finish()
                return
            }
            controlReceiveLoop(box, continuation)
        }
    }

    private func makeByteStream(_ box: ConnectionBox, firstChunk: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
            if !firstChunk.isEmpty { continuation.yield(firstChunk) }
            Self.receiveLoop(box, continuation)
        }
    }

    private nonisolated static func receiveLoop(
        _ box: ConnectionBox,
        _ continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            data, _, isComplete, error in
            if let data, !data.isEmpty { continuation.yield(data) }
            if let error {
                continuation.finish(throwing: error)
                return
            }
            if isComplete {
                continuation.finish()
                return
            }
            receiveLoop(box, continuation)
        }
    }
}

/// Resume a continuation at most once, even though `NWConnection`'s state
/// handler can fire repeatedly.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func tryResume(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
