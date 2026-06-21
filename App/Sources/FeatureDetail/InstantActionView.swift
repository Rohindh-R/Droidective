import ADBKit
import SwiftUI

/// Instant actions run straight from the sidebar (one click), so this pane is a
/// confirmation, not a gate: it shows what the last run produced and offers a
/// re-run. Before the first run it shows a single Run button and a hint that
/// clicking the sidebar row is enough.
struct InstantActionView: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef

    private var hasResult: Bool { state.lastResults[feature.id] != nil }

    var body: some View {
        VStack(spacing: 16) {
            if hasResult {
                LastResultCard(featureID: feature.id)
                    .frame(maxWidth: 460)
                Button {
                    run()
                } label: {
                    Label(state.isRunningFeature ? "Running…" : "Run again", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .disabled(state.isRunningFeature)
                .keyboardShortcut(.return, modifiers: .command)
            } else if state.isRunningFeature {
                ProgressView()
                    .controlSize(.large)
            } else {
                Button {
                    run()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)

                Text("Runs instantly. Tip: just click it in the sidebar — no need to open this.")
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func run() {
        Task { await state.run(feature: feature, params: [:]) }
    }
}
