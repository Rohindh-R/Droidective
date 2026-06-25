import ADBKit
import SwiftUI

/// Wireless ADB wizard (USB→tcpip bootstrap, Android 11+ pair, connect, and
/// per-device disconnect) as reusable cards, so it composes into both the
/// standalone screen and the Connection hub.
struct WirelessAdbSection: View {
    @Environment(AppState.self) private var state
    @State private var host = ""
    @State private var pairingPort = ""
    @State private var pairingCode = ""
    @State private var connectionPort = "5555"
    @State private var busy = false

    private var usbDevices: [Device] { state.devices.filter { !$0.isWireless && $0.isReady } }
    private var wirelessDevices: [Device] { state.devices.filter(\.isWireless) }

    var body: some View {
        HubSection("Wireless ADB", subtitle: "Switch a USB-connected device to debugging over Wi-Fi.") {
            if usbDevices.isEmpty {
                Text("Connect a device over USB to start.")
                    .foregroundStyle(.textMuted)
            } else {
                ForEach(usbDevices) { device in
                    HStack {
                        Text(device.label)
                        Spacer()
                        Button("Enable Wi-Fi & Connect") { enableTcpip(device.serial) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    }
                }
            }
        }

        HubSection("Pair a device", subtitle: "Android 11+ — pair with a code, then connect.") {
            HubField("Host / IP", prompt: "192.168.1.42", text: $host)
            HStack(spacing: 12) {
                HubField("Pairing port", prompt: "37123", text: $pairingPort)
                HubField("Pairing code", prompt: "123456", text: $pairingCode)
            }
            Button("Pair") { pair() }
                .buttonStyle(.bordered)
                .disabled(busy || host.isEmpty || pairingPort.isEmpty || pairingCode.isEmpty)

            Divider().padding(.vertical, 2)

            HubField("Connection port", prompt: "5555", text: $connectionPort)
            Button("Connect") { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(busy || host.isEmpty || connectionPort.isEmpty)

            Text("The pairing port (from \"Pair device with pairing code\") differs from the connection port shown on the device's Wireless debugging screen.")
                .font(.footnote)
                .foregroundStyle(.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !wirelessDevices.isEmpty {
            HubSection("Connected over Wi-Fi") {
                ForEach(wirelessDevices) { device in
                    HStack {
                        Text(device.label)
                        Spacer()
                        Button("Disconnect") { disconnect(device.serial) }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                    }
                }
            }
        }
    }

    private func runConnection(_ operation: @escaping @Sendable () async throws -> FeatureResult) {
        busy = true
        Task {
            await CommandLog.userInitiated(feature: "wireless-adb") {
                do {
                    let result = try await operation()
                    state.showToast(Toast(message: result.message, ok: result.ok, copyText: result.copyText, important: true))
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            busy = false
        }
    }

    private func enableTcpip(_ serial: String) {
        let connection = state.env.engine.connection
        runConnection { try await connection.enableTcpip(serial: serial) }
    }

    private func pair() {
        let connection = state.env.engine.connection
        let (h, p, c) = (host, pairingPort, pairingCode)
        runConnection { try await connection.pair(host: h, port: p, code: c) }
    }

    private func connect() {
        let connection = state.env.engine.connection
        let (h, p) = (host, connectionPort)
        runConnection { try await connection.connect(host: h, port: p) }
    }

    private func disconnect(_ serial: String) {
        let connection = state.env.engine.connection
        runConnection { try await connection.disconnect(target: serial) }
    }
}

/// Standalone Wireless ADB screen — the cards on their own in the hub column.
struct WirelessAdbView: View {
    var body: some View {
        HubColumn { WirelessAdbSection() }
    }
}
