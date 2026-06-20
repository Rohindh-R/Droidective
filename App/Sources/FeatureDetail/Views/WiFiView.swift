import ADBKit
import AppKit
import SwiftUI

/// Wi-Fi control: the current connection, an on/off toggle, a connect form,
/// and saved networks (with passwords revealed/copyable on a rooted device).
struct WiFiView: View {
    @Environment(AppState.self) private var state
    @State private var status: WifiStatus?
    @State private var networks: [WifiNetwork] = []
    @State private var hasRoot = false
    @State private var loaded = false
    @State private var busy = false
    @State private var revealed: Set<String> = []
    @State private var newSSID = ""
    @State private var newSecurity = "wpa2"
    @State private var newPassword = ""

    private var serial: String { state.targetSerials.first ?? "" }

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "wifi.slash",
                    description: Text("Connect a device to manage Wi-Fi.")
                )
            } else {
                content
            }
        }
        .task(id: state.targetSerials.first ?? "") { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                connectCard
                savedCard
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: (status?.connected ?? false) ? "wifi" : "wifi.slash")
                .font(.title)
                .foregroundStyle((status?.connected ?? false) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.title3).bold()
                if let status, status.connected {
                    let parts = [status.ipAddress, status.linkSpeed, status.frequency, status.signal].compactMap { $0 }
                    Text(parts.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(busy)
            Toggle("", isOn: Binding(get: { status?.enabled ?? false }, set: { on in Task { await setWifi(on) } }))
                .labelsHidden()
                .disabled(busy || status == nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var headline: String {
        if let ssid = status?.ssid { return ssid }
        return (status?.enabled ?? false) ? "Not connected" : "Wi-Fi off"
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to a network").font(.headline)
            HStack {
                TextField("SSID", text: $newSSID).textFieldStyle(.roundedBorder)
                Picker("", selection: $newSecurity) {
                    Text("WPA2").tag("wpa2")
                    Text("WPA3").tag("wpa3")
                    Text("Open").tag("open")
                }
                .labelsHidden()
                .frame(width: 110)
            }
            SecureField("Password (blank for open)", text: $newPassword).textFieldStyle(.roundedBorder)
            HStack {
                Text("`cmd wifi connect-network` (Android 11+); some ROMs block it over adb.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Connect") { Task { await connect() } }
                    .disabled(busy || newSSID.isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var savedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved networks").font(.headline)
                Spacer()
                if !hasRoot {
                    Label("Passwords need root", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if networks.isEmpty {
                Text(loaded ? "No saved networks reported (needs Android 11+)." : "Loading…")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(networks) { net in
                    savedRow(net)
                    if net.id != networks.last?.id { Divider() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func savedRow(_ net: WifiNetwork) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(net.ssid)
                HStack(spacing: 6) {
                    if let security = net.security {
                        Text(security).font(.caption).foregroundStyle(.secondary)
                    }
                    if let password = net.password, !password.isEmpty {
                        Text(revealed.contains(net.ssid) ? password : "••••••••")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
            if let password = net.password, !password.isEmpty {
                Button { toggleReveal(net.ssid) } label: {
                    Image(systemName: revealed.contains(net.ssid) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed.contains(net.ssid) ? "Hide" : "Reveal")
                Button { copy(password) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy password")
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        loaded = false
        guard !serial.isEmpty else { return }
        let engine = state.env.engine
        let result = await CommandLog.userInitiated(feature: "wifi") { () -> (WifiStatus, [WifiNetwork], Bool) in
            let status = await engine.wifi.status(serial: serial)
            var networks = await engine.wifi.savedNetworks(serial: serial)
            var rooted = false
            if await engine.root.detect(serial: serial).hasRootShell {
                rooted = true
                let creds = await engine.wifi.savedPasswords(serial: serial)
                var byssid: [String: String] = [:]
                for cred in creds where cred.password != nil { byssid[cred.ssid] = cred.password }
                networks = networks.map { network in
                    var network = network
                    network.password = byssid[network.ssid]
                    return network
                }
                let known = Set(networks.map(\.ssid))
                for cred in creds where !known.contains(cred.ssid) {
                    networks.append(WifiNetwork(networkId: nil, ssid: cred.ssid, security: cred.security, password: cred.password))
                }
            }
            return (status, networks, rooted)
        }
        guard !Task.isCancelled else { return }
        status = result.0
        networks = result.1
        hasRoot = result.2
        loaded = true
    }

    private func setWifi(_ on: Bool) async {
        busy = true
        defer { busy = false }
        await CommandLog.userInitiated(feature: "wifi") {
            let result = try? await state.env.engine.wifi.setEnabled(serial: serial, on)
            if result?.succeeded ?? false {
                state.showToast(Toast(message: "Wi-Fi \(on ? "on" : "off")", ok: true))
            } else {
                state.showToast(Toast(message: "Couldn't toggle Wi-Fi — the ROM may block svc wifi over adb.", ok: false))
            }
        }
        await load()
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        let ssid = newSSID
        await CommandLog.userInitiated(feature: "wifi") {
            let result = try? await state.env.engine.wifi.connect(
                serial: serial, ssid: ssid, security: newSecurity, password: newPassword
            )
            let output = ((result?.stdout ?? "") + (result?.stderr ?? "")).lowercased()
            let ok = (result?.succeeded ?? false) && !output.contains("fail") && !output.contains("error")
            state.showToast(Toast(
                message: ok ? "Connecting to \(ssid)…" : "Connect failed — the ROM may block it over adb.",
                ok: ok
            ))
        }
        newPassword = ""
        await load()
    }

    private func toggleReveal(_ ssid: String) {
        if revealed.contains(ssid) {
            revealed.remove(ssid)
        } else {
            revealed.insert(ssid)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.showToast(Toast(message: "Password copied", ok: true))
    }
}
