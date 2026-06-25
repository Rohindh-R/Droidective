import ADBKit
import SwiftUI

/// Simulate / Device State hub — fake battery, appearance, motion, layout,
/// locale, network, and proxy overrides on one screen. Each section runs the
/// matching feature; the individual features stay searchable + hotkey-able.
struct SimulateView: View {
    @Environment(AppState.self) private var state

    @State private var batteryLevel = 5.0
    @State private var batteryUnplugged = true
    @State private var fontScale = 1.0
    @State private var density = ""
    @State private var locale = "en-US"
    @State private var wifi = true
    @State private var data = true
    @State private var airplane = false
    @State private var proxy = ""

    var body: some View {
        HubColumn {
            if !state.activeOverrides.isEmpty {
                Button("Reset all overrides", role: .destructive) { state.resetAllOverrides() }
                    .buttonStyle(.bordered)
            }

            HubSection("Battery") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Level: \(Int(batteryLevel))%").foregroundStyle(.textMain)
                    Slider(value: $batteryLevel, in: 0...100, step: 1)
                }
                SwitchRow("Simulate unplugged", isOn: $batteryUnplugged)
                Button("Apply") {
                    run("fake-battery", ["level": .number(batteryLevel), "unplugged": .bool(batteryUnplugged)])
                }
                .buttonStyle(.borderedProminent)
            }

            HubSection("Appearance & motion") {
                if let darkMode = FeatureRegistry.byID["dark-mode"] {
                    HStack {
                        Text("Dark mode")
                        Spacer(minLength: 12)
                        OverrideToggleControl(feature: darkMode) { _ in EmptyView() }
                            .labelsHidden()
                    }
                }
                if let animations = FeatureRegistry.byID["animation-scale"] {
                    HStack {
                        Text("Disable animations (0×)")
                        Spacer(minLength: 12)
                        OverrideToggleControl(feature: animations) { _ in EmptyView() }
                            .labelsHidden()
                    }
                }
            }

            HubSection("Layout") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Font scale: \(fontScale, specifier: "%.2f")").foregroundStyle(.textMain)
                    Slider(value: $fontScale, in: 0.85...1.3, step: 0.05)
                }
                HubField("Display density", prompt: "dpi — blank to keep", text: $density)
                Button("Apply") {
                    var params: [String: FeatureValue] = ["fontScale": .number(fontScale)]
                    let raw = density.trimmingCharacters(in: .whitespaces)
                    if !raw.isEmpty, let value = Double(raw) { params["density"] = .number(value) }
                    run("layout-overrides", params)
                }
                .buttonStyle(.borderedProminent)
            }

            HubSection("Locale") {
                HStack {
                    Text("Language")
                    Spacer(minLength: 12)
                    Picker("", selection: $locale) {
                        ForEach(localeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Apply") { run("locale", ["locale": .string(locale)]) }
                    .buttonStyle(.borderedProminent)
            }

            HubSection("Network") {
                SwitchRow("Wi-Fi", isOn: $wifi)
                SwitchRow("Mobile data", isOn: $data)
                SwitchRow("Airplane mode", isOn: $airplane)
                Button("Apply") {
                    run("network-toggles", ["wifi": .bool(wifi), "data": .bool(data), "airplane": .bool(airplane)])
                }
                .buttonStyle(.borderedProminent)
            }

            HubSection("HTTP proxy", subtitle: "Route traffic through Charles, Proxyman, or mitmproxy.") {
                HubField("Proxy", prompt: "10.0.0.5:8888", text: $proxy)
                HStack(spacing: 10) {
                    Button("Set") { run("http-proxy", ["proxy": .string(proxy.trimmingCharacters(in: .whitespaces))]) }
                        .buttonStyle(.borderedProminent)
                        .disabled(proxy.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear") { run("http-proxy", ["proxy": .string("")]) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .disabled(state.targetSerials.isEmpty)
        .overlay {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to simulate its state.")
                )
            }
        }
    }

    private var localeOptions: [FieldOption] {
        FeatureRegistry.byID["locale"]?.fields.first?.options ?? []
    }

    private func run(_ id: String, _ params: [String: FeatureValue]) {
        guard let feature = FeatureRegistry.byID[id] else { return }
        Task { await state.run(feature: feature, params: params) }
    }
}
