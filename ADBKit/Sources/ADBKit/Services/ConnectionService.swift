import Foundation

/// Wireless adb: USB→tcpip bootstrap, Android 11+ pairing, and connect.
///
/// The Android 11 pairing port (under "Pair device with pairing code")
/// differs from the connection port on the main Wireless Debugging screen —
/// the UI collects both.
public struct ConnectionService: Sendable {
    let client: AdbClient
    let monitor: DeviceMonitor

    public init(client: AdbClient, monitor: DeviceMonitor) {
        self.client = client
        self.monitor = monitor
    }

    /// Put a USB-connected device into tcpip mode and connect to its ip:5555.
    public func enableTcpip(serial: String) async throws(AdbError) -> FeatureResult {
        let tcp = try await client.run(on: serial, ["tcpip", "5555"])
        guard tcp.succeeded else {
            return FeatureResult(ok: false, message: friendlyAdbError(tcp, fallback: "Failed to switch to tcpip mode"))
        }
        let wlan = try await client.run(on: serial, ["shell", "ip", "-f", "inet", "addr", "show", "wlan0"])
        guard let ip = FeatureEngine.parseIP(wlan.stdout) else {
            return FeatureResult(ok: true, message: "tcpip enabled, but couldn't read the device IP — check Wi-Fi.")
        }
        let address = "\(ip):5555"
        let connected = try await client.run(["connect", address])
        await monitor.invalidate()
        let success = connected.stdout.range(of: "connected|already", options: [.regularExpression, .caseInsensitive]) != nil
        return FeatureResult(
            ok: true,
            message: success ? "Connected over Wi-Fi: \(address)" : "tcpip enabled — connect to \(address)",
            copyText: address
        )
    }

    /// Android 11+ pairing with a code. host/port come from the pairing screen.
    public func pair(host: String, port: String, code: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(["pair", "\(host):\(port)", code], timeout: .seconds(20))
        if result.stdout.range(of: "Successfully paired", options: .caseInsensitive) != nil {
            return FeatureResult(ok: true, message: "Paired — now connect using the connection port.")
        }
        if result.stderr.range(of: "unknown command|usage: adb", options: [.regularExpression, .caseInsensitive]) != nil {
            return FeatureResult(ok: false, message: "Your adb is too old for pairing — update Android platform-tools (≥30).")
        }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeatureResult(
            ok: false,
            message: reason.isEmpty ? (fallback.isEmpty ? "Pairing failed (check the code/port)." : fallback) : reason
        )
    }

    public func connect(host: String, port: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(["connect", "\(host):\(port)"], timeout: .seconds(20))
        await monitor.invalidate()
        let success = result.stdout.range(of: "connected|already", options: [.regularExpression, .caseInsensitive]) != nil
        if success {
            return FeatureResult(ok: true, message: "Connected to \(host):\(port)")
        }
        let reason = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeatureResult(ok: false, message: reason.isEmpty ? "Connection failed." : reason)
    }

    public func disconnect(target: String?) async throws(AdbError) -> FeatureResult {
        let args = target.map { ["disconnect", $0] } ?? ["disconnect"]
        let result = try await client.run(args)
        await monitor.invalidate()
        return FeatureResult(
            ok: result.succeeded,
            message: target.map { "Disconnected \($0)" } ?? "Disconnected all wireless devices"
        )
    }
}
