import ADBKit
import AppKit
@preconcurrency import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    @MainActor static let globalLaunch = Self("globalLaunch")
}

/// Bridges KeyboardShortcuts (Carbon RegisterEventHotKey — no Accessibility
/// permission needed) to feature execution. Per-feature names are dynamic:
/// "feature-<id>".
@MainActor
enum HotkeyManager {
    private static var installed = false

    static func featureName(_ featureID: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("feature-\(featureID)")
    }

    /// "⌃⌥⇧⌘" string for the currently-held modifiers, in macOS display order —
    /// drives the live preview while recording a hotkey.
    static func symbolString(for flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// Register listeners for the global hotkey and every feature. Must run
    /// *after* the app finishes launching: Carbon installs its hot-key event
    /// handler on the dispatcher target live at first registration, so doing
    /// this in App.init() (before the event loop is up) leaves every shortcut
    /// silently dead. Called from RootView.onAppear instead. Idempotent — that
    /// can fire again when the window is reopened, and re-running would append
    /// duplicate handlers (the library appends, never replaces).
    static func install(state: AppState) {
        guard !installed else { return }
        installed = true
        KeyboardShortcuts.onKeyUp(for: .globalLaunch) { [weak state] in
            state?.activateMainWindow()
        }
        for feature in FeatureRegistry.all {
            KeyboardShortcuts.onKeyUp(for: featureName(feature.id)) { [weak state] in
                guard let state else { return }
                if feature.kind == .instantAction || feature.kind == .toggleAction {
                    Task { await state.run(feature: feature, params: [:]) }
                } else {
                    state.activateMainWindow()
                    state.requestFeature(feature.id)
                }
            }
        }
    }
}
