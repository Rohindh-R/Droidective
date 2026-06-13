import ADBKit
import SwiftUI

/// Amber pill in the device bar showing active device-state overrides, with
/// per-kind and reset-all actions.
struct OverridesPillView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if !state.activeOverrides.isEmpty {
            Menu {
                ForEach(state.activeOverrides) { override in
                    Button(role: .destructive) {
                        state.resetOverride(override.kind)
                    } label: {
                        Label("\(override.kind.label): \(override.value) — reset", systemImage: "xmark.circle")
                    }
                }
                Divider()
                Button("Reset all overrides", role: .destructive) {
                    state.resetAllOverrides()
                }
            } label: {
                Label(pillTitle, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .help("Device-state overrides are active")
        }
    }

    private var pillTitle: String {
        let overrides = state.activeOverrides
        if overrides.count == 1, let first = overrides.first {
            return first.kind.label
        }
        return "\(overrides.first?.kind.label ?? "") +\(overrides.count - 1)"
    }
}
