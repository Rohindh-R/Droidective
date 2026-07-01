import SwiftUI

/// Per-tab context handed down by the tab host (`TabHostView`). Open tabs all
/// stay mounted at once, so a view can't assume it's the one on screen — these
/// tell it which tab it lives in and whether that tab is currently visible.

private struct TabIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private struct TabFeatureIDKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// True when this view's tab is the foreground (visible) one. Backgrounded
    /// tabs stay mounted, so device-heavy *live* views (network/CPU polling, the
    /// screen mirror) read this to pause while hidden. Recordings and log streams
    /// deliberately ignore it and keep running. Defaults to true for views shown
    /// outside the tab host (Settings, sheets), which must never pause.
    var tabIsActive: Bool {
        get { self[TabIsActiveKey.self] }
        set { self[TabIsActiveKey.self] = newValue }
    }

    /// The feature id of the tab this view belongs to. A view registering a
    /// leave guard tags it with this so closing the right tab is what prompts —
    /// needed because the screenshot/video editors embed inside several
    /// different tabs (screen-record, scrcpy, their own).
    var tabFeatureID: String {
        get { self[TabFeatureIDKey.self] }
        set { self[TabFeatureIDKey.self] = newValue }
    }
}
