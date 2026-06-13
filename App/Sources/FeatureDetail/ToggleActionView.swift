import ADBKit
import SwiftUI

/// State-reflecting switch for toggle-action features (dark mode, demo mode,
/// animation scale). Current state comes from the reconciled overrides; user
/// flips are tracked as an in-flight intent so a quick on→off isn't swallowed
/// by stale reconciliation data.
struct ToggleActionView: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef

    @State private var isOn = false
    /// The value most recently sent to the device, until reconciliation
    /// catches up. nil = no run in flight.
    @State private var pendingValue: Bool?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: feature.icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .background(.tint.opacity(0.12), in: Circle())

            if let subtitle = feature.subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Toggle(isOn: $isOn) {
                Text(isOn ? (feature.toggleOnLabel ?? "On") : (feature.toggleOffLabel ?? "Off"))
            }
            .toggleStyle(.switch)
            .controlSize(.large)
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

            if state.targetSerials.isEmpty {
                Text("Connect a device to toggle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear { isOn = pendingValue ?? deviceState }
        .onChange(of: deviceState) { _, newValue in
            // Reconciliation only drives the switch when nothing is in flight.
            if pendingValue == nil {
                isOn = newValue
            }
        }
        .id(feature.id)
    }

    /// True when the reconciled overrides report this kind as active.
    private var deviceState: Bool {
        guard let kind = feature.overrideKind else { return false }
        return state.activeOverrides.contains { $0.kind == kind }
    }
}
