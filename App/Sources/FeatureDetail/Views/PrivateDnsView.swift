import ADBKit
import SwiftUI

/// Private DNS (DNS-over-TLS): off, automatic, or a specific provider hostname.
struct PrivateDnsView: View {
    @Environment(AppState.self) private var state
    @State private var mode = DnsStatus.Mode.automatic
    @State private var hostname = ""
    @State private var loaded = false
    @State private var busy = false

    private var serial: String { state.targetSerials.first ?? "" }

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to set Private DNS.")
                )
            } else {
                content
            }
        }
        .task(id: state.targetSerials.first ?? "") { await load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Private DNS", selection: $mode) {
                Text("Off").tag(DnsStatus.Mode.off)
                Text("Automatic").tag(DnsStatus.Mode.automatic)
                Text("Provider hostname").tag(DnsStatus.Mode.hostname)
            }
            .pickerStyle(.radioGroup)

            if mode == .hostname {
                TextField("dns.google", text: $hostname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }

            HStack {
                Button("Apply") { Task { await apply() } }
                    .disabled(busy || !loaded || (mode == .hostname && hostname.trimmingCharacters(in: .whitespaces).isEmpty))
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .centeredCard()
    }

    private func load() async {
        loaded = false
        guard !serial.isEmpty else { return }
        let status = await CommandLog.userInitiated(feature: "private-dns") {
            await state.env.engine.dns.current(serial: serial)
        }
        guard !Task.isCancelled else { return }
        mode = status.mode
        if let host = status.hostname { hostname = host }
        loaded = true
    }

    private func apply() async {
        busy = true
        defer { busy = false }
        let dns = state.env.engine.dns
        let host = hostname.trimmingCharacters(in: .whitespaces)
        await CommandLog.userInitiated(feature: "private-dns") {
            do {
                let result: AdbResult
                switch mode {
                case .off: result = try await dns.setOff(serial: serial)
                case .automatic: result = try await dns.setAutomatic(serial: serial)
                case .hostname: result = try await dns.setHostname(serial: serial, host)
                }
                state.showToast(Toast(
                    message: result.succeeded ? "Private DNS updated" : "Failed — \(result.stderr.isEmpty ? result.stdout : result.stderr)",
                    ok: result.succeeded
                ))
            } catch {
                state.showToast(Toast(message: error.localizedDescription, ok: false))
            }
        }
        await load()
    }
}
