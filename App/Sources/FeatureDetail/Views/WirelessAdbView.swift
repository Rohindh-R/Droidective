import ADBKit
import SwiftUI

/// Wireless ADB wizard (USB→tcpip bootstrap, Android 11+ pair, connect, and
/// per-device disconnect) as `Form` sections, so it composes into both the
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
        Section("Wireless ADB — over USB") {
            if usbDevices.isEmpty {
                Text("Connect a device over USB to bootstrap wireless ADB.")
                    .foregroundStyle(.textMuted)
            } else {
                ForEach(usbDevices) { device in
                    HStack {
                        Text(device.label)
                        Spacer()
                        Button("Enable Wi-Fi & Connect") {
                            enableTcpip(device.serial)
                        }
                        .disabled(busy)
                    }
                }
            }
        }

        Section("Pair (Android 11+)") {
            TextField("Host / IP", text: $host, prompt: Text("192.168.1.42"))
            TextField("Pairing port", text: $pairingPort, prompt: Text("37123"))
            TextField("Pairing code", text: $pairingCode, prompt: Text("123456"))
            Button("Pair") {
                pair()
            }
            .disabled(busy || host.isEmpty || pairingPort.isEmpty || pairingCode.isEmpty)

            TextField("Connection port", text: $connectionPort, prompt: Text("5555"))
            Button("Connect") {
                connect()
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || host.isEmpty || connectionPort.isEmpty)

            Text("The pairing port (from \"Pair device with pairing code\") differs from the connection port on the Wireless Debugging screen.")
                .font(.footnote)
                .foregroundStyle(.textMuted)
        }

        Section("Connected over Wi-Fi") {
            if wirelessDevices.isEmpty {
                Text("No wireless devices.")
                    .foregroundStyle(.textMuted)
            } else {
                ForEach(wirelessDevices) { device in
                    HStack {
                        Text(device.label)
                        Spacer()
                        Button("Disconnect") {
                            disconnect(device.serial)
                        }
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

/// Standalone Wireless ADB screen — the sections on their own in a grouped form.
struct WirelessAdbView: View {
    var body: some View {
        Form {
            WirelessAdbSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .centeredColumn()
    }
}
