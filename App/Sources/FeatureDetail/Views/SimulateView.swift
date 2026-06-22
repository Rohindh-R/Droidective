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
        Form {
            if !state.activeOverrides.isEmpty {
                Section {
                    Button("Reset all overrides", role: .destructive) { state.resetAllOverrides() }
                }
            }

            Section("Battery") {
                VStack(alignment: .leading) {
                    Text("Level: \(Int(batteryLevel))%")
                    Slider(value: $batteryLevel, in: 0...100, step: 1)
                }
                SwitchRow("Simulate unplugged", isOn: $batteryUnplugged)
                Button("Apply") {
                    run("fake-battery", ["level": .number(batteryLevel), "unplugged": .bool(batteryUnplugged)])
                }
            }

            Section("Appearance & Motion") {
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

            Section("Layout") {
                VStack(alignment: .leading) {
                    Text("Font scale: \(fontScale, specifier: "%.2f")")
                    Slider(value: $fontScale, in: 0.85...1.3, step: 0.05)
                }
                TextField("Density (dpi, blank = keep)", text: $density)
                    .brandField()
                    .frame(maxWidth: 200)
                Button("Apply") {
                    var params: [String: FeatureValue] = ["fontScale": .number(fontScale)]
                    let raw = density.trimmingCharacters(in: .whitespaces)
                    if !raw.isEmpty, let value = Double(raw) { params["density"] = .number(value) }
                    run("layout-overrides", params)
                }
            }

            Section("Locale") {
                Picker("Language", selection: $locale) {
                    ForEach(localeOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                Button("Apply") { run("locale", ["locale": .string(locale)]) }
            }

            Section("Network") {
                SwitchRow("Wi-Fi", isOn: $wifi)
                SwitchRow("Mobile data", isOn: $data)
                SwitchRow("Airplane mode", isOn: $airplane)
                Button("Apply") {
                    run("network-toggles", ["wifi": .bool(wifi), "data": .bool(data), "airplane": .bool(airplane)])
                }
            }

            Section("Proxy") {
                TextField("Proxy (host:port)", text: $proxy)
                    .brandField()
                    .frame(maxWidth: 200)
                HStack {
                    Button("Set") { run("http-proxy", ["proxy": .string(proxy.trimmingCharacters(in: .whitespaces))]) }
                        .disabled(proxy.trimmingCharacters(in: .whitespaces).isEmpty)
                    // Clear via the feature (empty proxy → engine resets it) so it
                    // lands in the command log like Set, instead of a silent reset.
                    Button("Clear") { run("http-proxy", ["proxy": .string("")]) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
