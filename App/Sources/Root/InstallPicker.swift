import ADBKit
import AppKit
import SwiftUI

/// Buffers APKs opened from Finder until the UI is ready to show the picker —
/// a double-clicked APK can reach the app delegate before `RootView` appears on
/// a cold launch.
@MainActor
final class InstallInbox {
    static let shared = InstallInbox()
    private var pending: [URL] = []
    var onReceive: (([URL]) -> Void)? { didSet { drain() } }

    func receive(_ urls: [URL]) {
        pending.append(contentsOf: urls)
        drain()
    }

    private func drain() {
        guard let onReceive, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        onReceive(urls)
    }
}

/// Borderless floating panel (same chrome as the ⌘K palette) that asks which
/// connected device to install an opened APK onto.
@MainActor
final class InstallPickerController {
    static let shared = InstallPickerController()
    private var panel: KeyablePanel?

    func present(apks: [URL], state: AppState) {
        close()
        let view = InstallPickerView(apks: apks, onClose: { [weak self] in self?.close() })
            .environment(state)
            .tint(.brandAccent)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let panel = KeyablePanel(contentViewController: hosting)
        panel.styleMask = [.borderless]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = panel.screen ?? NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.midY - frame.height / 2
            ))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct InstallPickerView: View {
    @Environment(AppState.self) private var state
    let apks: [URL]
    let onClose: () -> Void

    private var ready: [Device] { state.devices.filter(\.isReady) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if ready.isEmpty {
                Text("No device connected. Connect one, then reopen the APK.")
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .padding(16)
            } else {
                ForEach(ready) { device in
                    row(label: device.label, sub: device.serial, icon: "iphone") {
                        state.installAPKs(apks, onSerials: [device.serial])
                    }
                }
                if ready.count > 1 {
                    Divider()
                    row(label: "Install on all devices", sub: "\(ready.count) devices", icon: "square.stack.3d.up") {
                        state.installAPKs(apks, onSerials: ready.map(\.serial))
                    }
                }
            }
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app")
                .font(.title2)
                .foregroundStyle(.brandAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Install").font(.headline)
                Text(apks.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func row(label: String, sub: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onClose()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.brandAccent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
