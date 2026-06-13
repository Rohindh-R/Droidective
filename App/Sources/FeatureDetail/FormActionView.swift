import ADBKit
import SwiftUI

/// Generic form generated from a feature's `[FieldDef]`. Field values are
/// kept as strings/bools and converted to `FeatureValue` on submit.
struct FormActionView: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef

    @State private var textValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var sliderValues: [String: Double] = [:]
    @State private var presets = Presets()

    var body: some View {
        Form {
            ForEach(feature.fields, id: \.name) { field in
                control(for: field)
            }

            HStack {
                Button {
                    submit()
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isRunningFeature)
                .keyboardShortcut(.return, modifiers: .command)

                Text("⌘⏎")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            LastResultCard(featureID: feature.id)
        }
        .formStyle(.grouped)
        .onAppear { seedDefaults() }
        .task {
            presets = await state.env.stores.presets.load()
        }
        .id(feature.id)
    }

    private func presetValues(for key: String) -> [String] {
        switch key {
        case "reversePorts": return presets.reversePorts.map(String.init)
        case "proxies": return presets.proxies
        default: return []
        }
    }

    @ViewBuilder
    private func control(for field: FieldDef) -> some View {
        switch field.control {
        case .text, .number, .bundle:
            TextField(field.label, text: binding(for: field), prompt: field.placeholder.map(Text.init))
        case .preset:
            HStack {
                TextField(field.label, text: binding(for: field), prompt: field.placeholder.map(Text.init))
                let values = presetValues(for: field.presetKey ?? "")
                if !values.isEmpty {
                    Menu {
                        ForEach(values, id: \.self) { value in
                            Button(value) { textValues[field.name] = value }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        case .select:
            Picker(field.label, selection: binding(for: field)) {
                ForEach(field.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .switch:
            Toggle(field.label, isOn: boolBinding(for: field))
        case .slider:
            let range = (field.min ?? 0)...(field.max ?? 1)
            VStack(alignment: .leading) {
                Text("\(field.label): \(sliderValues[field.name] ?? defaultSlider(field), specifier: "%.2f")")
                Slider(value: sliderBinding(for: field), in: range, step: field.step ?? 1)
            }
        }
    }

    private func seedDefaults() {
        for field in feature.fields {
            switch field.defaultValue {
            case .string(let value) where textValues[field.name] == nil:
                textValues[field.name] = value
            case .bool(let value) where boolValues[field.name] == nil:
                boolValues[field.name] = value
            case .number(let value):
                if field.control == .slider, sliderValues[field.name] == nil {
                    sliderValues[field.name] = value
                } else if textValues[field.name] == nil {
                    // No locale grouping — "1,000" wouldn't round-trip.
                    textValues[field.name] = value == value.rounded()
                        ? String(Int(value))
                        : String(value)
                }
            default:
                break
            }
        }
    }

    private func submit() {
        var params: [String: FeatureValue] = [:]
        for field in feature.fields {
            switch field.control {
            case .switch:
                params[field.name] = .bool(boolValues[field.name] ?? (field.defaultValue?.boolValue ?? false))
            case .slider:
                params[field.name] = .number(sliderValues[field.name] ?? defaultSlider(field))
            case .number:
                let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespaces)
                if raw.isEmpty { break }
                guard let value = Double(raw.replacingOccurrences(of: ",", with: "")) else {
                    state.showToast(Toast(message: "\"\(raw)\" isn't a valid number for \(field.label).", ok: false))
                    return
                }
                params[field.name] = .number(value)
            default:
                if let value = textValues[field.name], !value.isEmpty {
                    params[field.name] = .string(value)
                }
            }
        }
        Task { await state.run(feature: feature, params: params) }
    }

    private func defaultSlider(_ field: FieldDef) -> Double {
        field.defaultValue?.numberValue ?? field.min ?? 0
    }

    private func binding(for field: FieldDef) -> Binding<String> {
        Binding(
            get: { textValues[field.name] ?? "" },
            set: { textValues[field.name] = $0 }
        )
    }

    private func boolBinding(for field: FieldDef) -> Binding<Bool> {
        Binding(
            get: { boolValues[field.name] ?? (field.defaultValue?.boolValue ?? false) },
            set: { boolValues[field.name] = $0 }
        )
    }

    private func sliderBinding(for field: FieldDef) -> Binding<Double> {
        Binding(
            get: { sliderValues[field.name] ?? defaultSlider(field) },
            set: { sliderValues[field.name] = $0 }
        )
    }

}
