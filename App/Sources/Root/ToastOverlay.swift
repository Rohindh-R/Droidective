import AppKit
import SwiftUI

/// Transient toasts, stacked top-right under the notifications bell. The
/// important ones are also kept in the notifications panel.
struct ToastOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(state.toasts) { toast in
                ToastView(toast: toast)
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 16)
        .animation(.spring(duration: 0.25), value: state.toasts)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ToastStyle.icon(toast.level))
                .foregroundStyle(ToastStyle.color(toast.level))
            Text(toast.message)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let copyText = toast.copyText {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let revealPath = toast.revealPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ToastStyle.color(toast.level))
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Shared severity icon/color mapping for toasts and notification rows.
enum ToastStyle {
    static func icon(_ level: Toast.Level) -> String {
        switch level {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    static func color(_ level: Toast.Level) -> Color {
        switch level {
        case .success: Color("BrandAccent")
        case .info: Color("TextMuted")
        case .warning: .warning
        case .error: .danger
        }
    }
}
