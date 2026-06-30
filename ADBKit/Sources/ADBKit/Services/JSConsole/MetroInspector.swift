import Foundation

/// One debuggable JavaScript target advertised by the Metro inspector proxy.
///
/// React Native (Hermes) dev builds register a Chrome DevTools Protocol target
/// with Metro, listed at `GET http://<host>:<port>/json/list`. The
/// `webSocketDebuggerUrl` is a raw CDP WebSocket; `logicalDeviceId` is stable
/// across JS reloads (so it's the right key to reconnect by), while `id` and the
/// `page` in the URL can change on relaunch.
public struct CDPTarget: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let appId: String?
    public let detail: String
    public let deviceName: String
    public let vm: String?
    public let webSocketDebuggerUrl: String
    public let logicalDeviceId: String?

    /// The Hermes JS target — the one a console attaches to. Older proxies also
    /// list a placeholder entry with `vm == "don't use"`, which is filtered out
    /// during parsing.
    public var isHermes: Bool { vm == "Hermes" }

    public init(
        id: String, title: String, appId: String?, detail: String,
        deviceName: String, vm: String?, webSocketDebuggerUrl: String, logicalDeviceId: String?
    ) {
        self.id = id
        self.title = title
        self.appId = appId
        self.detail = detail
        self.deviceName = deviceName
        self.vm = vm
        self.webSocketDebuggerUrl = webSocketDebuggerUrl
        self.logicalDeviceId = logicalDeviceId
    }
}

/// Discovers and lists React Native debug targets from the Metro inspector
/// proxy on the host. Pure JSON parsing lives in `parseTargets` (tested without
/// a network); the fetch is a plain host-localhost HTTP GET — no adb, no device,
/// because Metro and its proxy run on the Mac and the device only connects *out*
/// to them.
public struct MetroInspector: Sendable {
    public enum MetroError: Error, Sendable, LocalizedError, Equatable {
        case notRunning(port: Int)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case let .notRunning(port): "No Metro server answering on port \(port)."
            case .badResponse: "Metro returned an unexpected response."
            }
        }
    }

    public let host: String
    public let port: Int
    private let timeout: TimeInterval

    public init(host: String = "127.0.0.1", port: Int = 8081, timeout: TimeInterval = 4) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    /// Parse `/json/list` JSON into targets. Drops entries with no debugger URL
    /// and the legacy `vm == "don't use"` placeholder, and sorts Hermes targets
    /// first. Pure and static so it's unit-tested directly.
    public static func parseTargets(_ data: Data) -> [CDPTarget] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let array = root.arrayValue else { return [] }
        let targets: [CDPTarget] = array.compactMap { entry in
            guard let ws = entry["webSocketDebuggerUrl"]?.stringValue, !ws.isEmpty else { return nil }
            let vm = entry["vm"]?.stringValue
            if vm == "don't use" { return nil }
            return CDPTarget(
                id: entry["id"]?.stringValue ?? ws,
                title: entry["title"]?.stringValue ?? "React Native",
                appId: entry["appId"]?.stringValue,
                detail: entry["description"]?.stringValue ?? entry["appId"]?.stringValue ?? "",
                deviceName: entry["deviceName"]?.stringValue ?? "",
                vm: vm,
                webSocketDebuggerUrl: ws,
                logicalDeviceId: entry["reactNative"]?["logicalDeviceId"]?.stringValue
            )
        }
        return targets.sorted { lhs, rhs in
            lhs.isHermes && !rhs.isHermes
        }
    }

    /// Whether a target's `webSocketDebuggerUrl` is a local debugger socket. The
    /// proxy runs on the host, so a legitimate target is always `ws(s)` on
    /// loopback; refusing anything else stops a rogue local process on the Metro
    /// port from steering the console at an off-host WebSocket.
    public static func isLocalDebuggerURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else { return false }
        let host = (url.host ?? "").lowercased()
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    /// Fetch the live target list. Throws `.notRunning` when nothing answers on
    /// the port (Metro down, or the device hasn't connected yet).
    public func listTargets() async throws(MetroError) -> [CDPTarget] {
        let data = try await get("/json/list")
        return Self.parseTargets(data)
    }

    /// Whether a Metro dev server is answering on the port. `/status` returns
    /// `packager-status:running` when it's up.
    public func isMetroRunning() async -> Bool {
        guard let data = try? await get("/status") else { return false }
        return String(decoding: data, as: UTF8.self).contains("packager-status:running")
    }

    private func get(_ path: String) async throws(MetroError) -> Data {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw .badResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .notRunning(port: port)
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw .badResponse
        }
        return data
    }
}
