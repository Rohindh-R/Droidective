import ADBKit
import SwiftUI

/// First-launch full-window takeover: the user picks a role and gets a focused
/// set of features instead of all of them — the answer to "this app is
/// overwhelming". Skippable ("Show me everything") and changeable later from
/// Settings. Selecting a role seeds the curated set via `AppState.chooseRole`.
///
/// Presented as a full-bleed overlay (not a sheet) so it genuinely takes over
/// the window; macOS has no `fullScreenCover`.
struct RolePickerView: View {
    @Environment(AppState.self) private var state
    @AppStorage("hasChosenRole") private var hasChosenRole = false

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 28) {
            header
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(UserRole.allCases) { role in
                    RoleCard(role: role) { choose(role) }
                }
            }
            .frame(maxWidth: 560)
            Button("Show me everything") { choose(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.textMuted)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bgRoot)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 42))
                .foregroundStyle(.brandAccent)
                .symbolRenderingMode(.hierarchical)
            Text("What do you do?")
                .font(.largeTitle.bold())
                .foregroundStyle(.textMain)
            Text("Pick a role and we'll start you with the tools you'll use most. "
                + "Everything else is one click away — and you can change this anytime.")
                .font(.body)
                .foregroundStyle(.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose(_ role: UserRole?) {
        hasChosenRole = true
        state.chooseRole(role)
    }
}

/// One selectable role tile — icon, name, and a one-line description, with the
/// brand-green hover border used elsewhere in the app.
private struct RoleCard: View {
    let role: UserRole
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: role.icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.brandAccent)
                    .symbolRenderingMode(.hierarchical)
                Text(role.label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.textMain)
                Text(role.blurb)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(18)
            .background(.bgSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        hovering ? Color.brandAccent : Color.borderSubtle,
                        lineWidth: hovering ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}
