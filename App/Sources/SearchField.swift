import SwiftUI

/// A text field that reads as search: a leading magnifying glass, a clear
/// button once there's text, and the same brand-green focus ring as
/// ``brandField()`` (which on its own carries no search affordance).
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var controlActive

    private var ringVisible: Bool { focused && controlActive != .inactive }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.textMuted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.textMuted)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    ringVisible ? Color.brandAccent : Color.borderSubtle,
                    lineWidth: ringVisible ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
