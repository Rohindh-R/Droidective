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
    static func featureName(_ featureID: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("feature-\(featureID)")
    }

    /// Register listeners once at launch for the global hotkey and every
    /// instant-action feature (other kinds need UI input, so the hotkey just
    /// focuses them).
    static func install(state: AppState) {
        KeyboardShortcuts.onKeyUp(for: .globalLaunch) { [weak state] in
            state?.activateMainWindow()
        }
        for feature in FeatureRegistry.all {
            KeyboardShortcuts.onKeyUp(for: featureName(feature.id)) { [weak state] in
                guard let state else { return }
                if feature.kind == .instantAction {
                    Task { await state.run(feature: feature, params: [:]) }
                } else {
                    state.activateMainWindow()
                    state.selectedFeatureID = feature.id
                }
            }
        }
    }
}
