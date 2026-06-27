import Foundation

/// Buffers APKs opened from Finder until the UI is ready to receive them — a
/// double-clicked APK can reach the app delegate before `RootView` appears on a
/// cold launch. Drained to `onReceive` (set by RootView), which routes them to
/// the Install App feature.
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
