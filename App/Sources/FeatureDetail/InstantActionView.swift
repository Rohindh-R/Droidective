import ADBKit
import SwiftUI

struct InstantActionView: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: feature.icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 84, height: 84)
                .background(.tint.opacity(0.12), in: Circle())

            if let subtitle = feature.subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button {
                Task { await state.run(feature: feature, params: [:]) }
            } label: {
                Label("Run", systemImage: "play.fill")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.isRunningFeature)
            .keyboardShortcut(.return, modifiers: .command)

            Text("⌘⏎ to run")
                .font(.caption)
                .foregroundStyle(.tertiary)

            LastResultCard(featureID: feature.id)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
