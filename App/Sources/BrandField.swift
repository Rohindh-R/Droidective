import SwiftUI

/// A rounded-border text field whose focus ring is the brand green on every
/// Mac, not the user's system accent color.
///
/// macOS draws the focus ring on a *bezeled* text field (`.roundedBorder`) from
/// the *system* accent color (System Settings → Appearance → Accent color).
/// That path ignores the app's `.tint(.brandAccent)`, the `AccentColor` asset,
/// and even `.focusEffectDisabled()`, so on a Mac whose accent is a specific
/// color the ring renders in that color (e.g. blue) instead of green. A
/// `.plain` field draws no ring at all, so this styles the field ourselves —
/// a subtle resting border that turns brand-green on focus — giving an
/// identical result regardless of the machine's accent setting.
///
/// Each application carries its own `@FocusState`; it composes with any
/// external `.focused(_:)` a call site already has (both reflect the same
/// focus). The two pre-existing `.plain` fields (palette search, screenshot
/// canvas text) keep their own chrome and don't use this.
///
/// The ring is gated on `controlActiveState` so it dims to the resting border
/// when the window goes inactive — `@FocusState` stays set while another app is
/// frontmost, and `.brandAccent` (a named asset color) doesn't desaturate on
/// its own, so without this the ring would stay bright green after the user
/// clicks away. A native focus ring dims when the window loses key; this mirrors
/// that.
private struct BrandFieldModifier: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var controlActive

    private var ringVisible: Bool { focused && controlActive != .inactive }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ringVisible ? Color.brandAccent : Color.borderSubtle, lineWidth: ringVisible ? 2 : 1)
            }
    }
}

extension View {
    /// Rounded-border text-field style with a brand-green focus ring that is
    /// consistent across Macs (see ``BrandFieldModifier``).
    func brandField() -> some View { modifier(BrandFieldModifier()) }
}
