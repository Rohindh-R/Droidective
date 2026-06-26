import Foundation

/// Orchestrates the Reactotron server for a device session: brings up the
/// WebSocket server, opens the `adb reverse` tunnel so the device's
/// localhost:9090 reaches the Mac, and tears both down on stop. The timeline
/// view owns one of these, mirroring how `LogcatView` owns a `LogcatStreamer`.
public actor ReactotronService {
    private let client: AdbClient
    private let port: UInt16
    private let server: ReactotronServer

    public init(client: AdbClient, port: UInt16 = 9090) {
        self.client = client
        self.port = port
        self.server = ReactotronServer(port: port)
    }

    /// Start the WebSocket server. Call `reverse(serials:)` to open the adb
    /// tunnels separately so the UI can report per-device success.
    public func start() async throws -> AsyncStream<ReactotronServer.Event> {
        try await server.start()
    }

    public struct ReverseResult: Sendable {
        public let serial: String
        public let ok: Bool
        public let detail: String
    }

    /// Open `adb reverse tcp:9090 tcp:9090` on each serial so the device's
    /// localhost:9090 reaches this server. Retries a few times — a freshly
    /// booted/attached device can briefly reject reverse. Returns per-serial
    /// success + the adb error on failure so the UI can report it.
    @discardableResult
    public func reverse(serials: [String]) async -> [ReverseResult] {
        var results: [ReverseResult] = []
        for serial in serials {
            results.append(await reverseOne(serial))
        }
        return results
    }

    private func reverseOne(_ serial: String, attempts: Int = 3) async -> ReverseResult {
        var lastDetail = "no attempt"
        for attempt in 0 ..< attempts {
            do {
                let result = try await client.run(on: serial, ["reverse", "tcp:\(port)", "tcp:\(port)"])
                if result.succeeded {
                    return ReverseResult(serial: serial, ok: true, detail: "")
                }
                lastDetail = "exit \(result.exitCode.map(String.init) ?? "nil"): \(result.stderr)"
            } catch {
                lastDetail = "\(error)"
            }
            if attempt < attempts - 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return ReverseResult(
            serial: serial, ok: false,
            detail: lastDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Stop the server and remove the reverse tunnels. Safe to call repeatedly.
    public func stop(serials: [String]) async {
        await server.stop()
        for serial in serials {
            _ = try? await client.run(on: serial, ["reverse", "--remove", "tcp:\(port)"])
        }
    }

    /// Send a server→client frame to a specific connection.
    public func send(type: String, payload: JSONValue, toConnection id: Int) async {
        await server.send(type: type, payload: payload, toConnection: id)
    }

    /// Broadcast a server→client frame to every connected client.
    public func broadcast(type: String, payload: JSONValue) async {
        await server.broadcast(type: type, payload: payload)
    }

    /// The adb command we run per device — surfaced for the Commands tab / notes.
    public var reverseCommand: String {
        "adb reverse tcp:\(port) tcp:\(port)"
    }
}
