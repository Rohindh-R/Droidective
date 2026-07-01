import AppKit
import SwiftUI

/// App color tokens — the "Terminal" (dark) / "Lab" (light) palette, sourced
/// from the asset catalog with a light + dark variant per token.
///
/// These are *named* asset colors, not the system accent. A named asset color
/// resolves statically and keeps its value when the window goes inactive,
/// whereas `.tint` / `Color.accentColor` desaturate to graphite on focus loss.
/// So accent-colored icons, text, and highlights use `.brandAccent` here and
/// stay put on focus change.
///
/// Icon usage (the matrix): static-navigation and input icons are `.textMuted`;
/// resting-action icons inherit `.textMain`; active/selected icons, loaders, and
/// CTAs are `.brandAccent`.
extension ShapeStyle where Self == Color {
    /// Deepest layer — the content background (the "graphite case").
    static var bgRoot: Color { Color("BgRoot") }
    /// Lifted surface — sidebar, cards, and bars sit one step above `bgRoot`.
    static var bgSurface: Color { Color("BgSurface") }
    /// Thin dividers and borders.
    static var borderSubtle: Color { Color("BorderSubtle") }
    /// Primary reading text, header titles, active values, resting-action icons.
    static var textMain: Color { Color("TextMain") }
    /// Subtitles, timestamps, labels, and quiet navigation/input icons.
    static var textMuted: Color { Color("TextMuted") }
    /// "The electricity" — CTAs, active toggles, selection, loaders, logo mark.
    /// Honors a user-chosen accent (Settings ▸ General) when set, otherwise the
    /// bundled asset. A fixed color either way, so it doesn't desaturate on focus
    /// loss the way the system accent would. Read fresh per render; the app keys
    /// its root view on the stored accent so a change rebuilds and re-reads it.
    static var brandAccent: Color {
        if let hex = UserDefaults.standard.string(forKey: accentColorDefaultsKey),
           let custom = Color(hex: hex) {
            return custom
        }
        return Color("BrandAccent")
    }
}

/// UserDefaults key for the user-chosen accent (hex like "#34C759"). Empty or
/// unset → the bundled BrandAccent asset.
let accentColorDefaultsKey = "accentColorHex"

extension Color {
    /// Parse "#RRGGBB" / "RRGGBB" as sRGB. nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// "#RRGGBB" in sRGB, or nil if the color can't be resolved to RGB.
    var hexString: String? {
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(resolved.redComponent * 255)),
            Int(round(resolved.greenComponent * 255)),
            Int(round(resolved.blueComponent * 255)))
    }

    /// A readable foreground (white or near-black) for text drawn on top of this
    /// background, resolving the background in the given color scheme first.
    /// Uses a perceptual luminance estimate — Rec. 709 weights on gamma-encoded
    /// sRGB, an approximation of WCAG relative luminance (not the linearized form)
    /// — picking `Color.black.opacity(0.85)` for light backgrounds and `.white` for
    /// dark ones (threshold: luminance > 0.35). When the background can't be
    /// resolved, falls back to the scheme's own contrasting default.
    func contrastingForeground(for scheme: ColorScheme) -> Color {
        let fallback: Color = scheme == .dark ? .white : Color.black.opacity(0.85)
        guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) else { return fallback }
        var foreground = fallback
        appearance.performAsCurrentDrawingAppearance {
            if let resolved = Self.luminanceForeground(of: self) { foreground = resolved }
        }
        return foreground
    }

    /// Resolve a named asset color to a concrete, appearance-independent color
    /// for a specific scheme.
    ///
    /// SwiftUI hosts a `Menu`'s pop-up-button label in a context whose effective
    /// appearance we don't control (it flattens the label to one tint resolved
    /// against the control's own — stuck-dark — appearance), so an env-resolved
    /// asset like `.textMain` renders near-white there in *both* modes, going
    /// white-on-white in light mode. Feeding the label a pre-resolved concrete
    /// color sidesteps that. Falls back to the dynamic asset if resolution fails.
    static func resolved(_ name: String, for scheme: ColorScheme) -> Color {
        guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua),
              let dynamic = NSColor(named: name) else { return Color(name) }
        var flat = dynamic
        appearance.performAsCurrentDrawingAppearance {
            flat = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return Color(nsColor: flat)
    }

    /// Same logic without an appearance context — for static (non-adaptive) colors
    /// built from explicit RGB/HSB values, which have no light/dark variant to resolve.
    var contrastingForeground: Color { Self.luminanceForeground(of: self) ?? .white }

    /// Returns the contrasting foreground for `color`, or nil if it can't be
    /// resolved to sRGB (e.g. a catalog color with no current drawing appearance).
    private static func luminanceForeground(of color: Color) -> Color? {
        guard let nc = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let lum = 0.2126 * nc.redComponent + 0.7152 * nc.greenComponent + 0.0722 * nc.blueComponent
        return lum > 0.35 ? Color.black.opacity(0.85) : .white
    }
}
