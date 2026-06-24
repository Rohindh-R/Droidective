import SwiftUI

/// One-time nudge to star the project on GitHub, shown once the app has been
/// launched several times (gated in RootView, after the privacy consent). Marks
/// itself shown the moment it appears, so it never nags twice — whatever the
/// user does with it.
struct StarPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("starPromptShown") private var starPromptShown = false

    /// Opens the GitHub repository (routed through AppState so views stay thin).
    let onStar: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "star.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.brandAccent)
                .frame(width: 64, height: 64)
                .background(Color.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 7) {
                Text("Enjoying Droidective?")
                    .font(.title2.bold())
                Text("A star on GitHub helps other Android and React Native developers find it. It takes a moment and genuinely helps.")
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button {
                    onStar()
                    dismiss()
                } label: {
                    Label("Star on GitHub", systemImage: "star.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .tint(.brandAccent)

                Button("Maybe Later") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
            }
        }
        .padding(28)
        .frame(width: 380)
        .background(Color.bgRoot)
        .onAppear { starPromptShown = true }
    }
}
