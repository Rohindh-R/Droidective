import AppKit
import SwiftUI

struct ToastOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 6) {
            ForEach(state.toasts) { toast in
                ToastView(toast: toast)
            }
        }
        .padding(.bottom, 16)
        .animation(.spring(duration: 0.25), value: state.toasts)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(toast.ok ? .green : .red)
            Text(toast.message)
                .lineLimit(2)

            if let copyText = toast.copyText {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let revealPath = toast.revealPath {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
