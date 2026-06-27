import AppKit
import SwiftUI

/// The notifications history: a persistent right column listing the important
/// notifications (errors, warnings, key wins). Toggled by the bell in the
/// device bar.
struct NotificationPanelView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.notifications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.notifications) { note in
                            NotificationRow(note: note)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bgSurface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Notifications")
                .font(.headline)
            Spacer()
            if state.notifications.count > 1 {
                Button("Clear all") { state.clearNotifications() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .help("Clear all notifications")
            }
            Button {
                state.toggleNotifications()
            } label: {
                Image(systemName: "xmark")
                    .font(.body)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.textMuted)
            .help("Close notifications")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(.textMuted)
            Text("No notifications")
                .font(.callout)
                .foregroundStyle(.textMain)
            Text("Errors, warnings, and key results show up here.")
                .font(.footnote)
                .foregroundStyle(.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotificationRow: View {
    @Environment(AppState.self) private var state
    let note: AppNotification
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ToastStyle.icon(note.level))
                .foregroundStyle(ToastStyle.color(note.level))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(note.message)
                    .font(.callout)
                    .foregroundStyle(.textMain)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(note.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.textMuted)
                    if let revealPath = note.revealPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: revealPath)]
                            )
                        } label: {
                            Label("Reveal", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if let copyText = note.copyText {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copyText, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
            if hovering {
                Button { state.dismissNotification(note.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.textMuted)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? AnyShapeStyle(.brandAccent.opacity(0.08)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
    }
}

/// The bell that toggles the notifications panel, with an unread badge. Lives
/// at the top-right of the device bar so toasts drop from underneath it.
struct NotificationBell: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.toggleNotifications()
        } label: {
            Image(systemName: state.showNotifications ? "bell.fill" : "bell")
                .font(.body)
                .frame(width: 24, height: 22)
                .overlay(alignment: .topTrailing) {
                    if state.unreadNotifications > 0 && !state.showNotifications {
                        Text(state.unreadNotifications > 99 ? "99+" : "\(state.unreadNotifications)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 9)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 6, y: -5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.showNotifications ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
        .help(state.showNotifications ? "Hide notifications" : "Show notifications")
    }
}
