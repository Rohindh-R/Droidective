import ADBKit
import SwiftUI

/// A switch bound to a device override (dark mode, demo mode, animation scale).
/// Current state comes from the reconciled overrides; a user flip is held as an
/// in-flight intent so a quick on→off isn't swallowed by stale reconciliation.
/// Shared by the sidebar row (label-less) and the detail pane (on/off label).
struct OverrideToggleControl<Label: View>: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef
    @ViewBuilder var label: (Bool) -> Label

    @State private var isOn = false
    /// The value most recently sent to the device, until reconciliation catches
    /// up. nil = no run in flight.
    @State private var pendingValue: Bool?

    var body: some View {
        Toggle(isOn: $isOn) { label(isOn) }
            .toggleStyle(.switch)
            .disabled(state.targetSerials.isEmpty)
            .onChange(of: isOn) { _, newValue in
                let current = pendingValue ?? deviceState
                guard newValue != current else { return }
                pendingValue = newValue
                Task {
                    await state.run(feature: feature, params: ["on": .bool(newValue)])
                    // Only clear if no newer flip superseded this one.
                    if pendingValue == newValue {
                        pendingValue = nil
                    }
                }
            }
            .onAppear { isOn = pendingValue ?? deviceState }
            .onChange(of: deviceState) { _, newValue in
                // Reconciliation only drives the switch when nothing is in flight.
                if pendingValue == nil {
                    isOn = newValue
                }
            }
    }

    /// True when the reconciled overrides report this kind as active.
    private var deviceState: Bool {
        guard let kind = feature.overrideKind else { return false }
        return state.activeOverrides.contains { $0.kind == kind }
    }
}

/// A form switch whose label is inert — only the switch itself flips it. macOS
/// makes a bare `Toggle`'s whole row a tap target, which surprised users who
/// clicked a row's text or empty space and saw the switch flip.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

/// State-reflecting switch for toggle-action features in the detail pane. The
/// same flip is also available inline on the sidebar row.
struct ToggleActionView: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverrideToggleControl(feature: feature) { isOn in
                Text(isOn ? (feature.toggleOnLabel ?? "On") : (feature.toggleOffLabel ?? "Off"))
            }
            .controlSize(.large)

            if state.targetSerials.isEmpty {
                Text("Connect a device to toggle.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
        }
        .centeredCard()
        .id(feature.id)
    }
}
