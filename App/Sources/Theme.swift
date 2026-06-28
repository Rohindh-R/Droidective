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

    /// The foreground color (white or near-black) that provides adequate contrast against
    /// this background color when rendered in the given color scheme.
    /// Uses WCAG relative luminance — picks `.white` for dark backgrounds and
    /// `Color.black.opacity(0.85)` for light ones (threshold: luminance > 0.35).
    func contrastingForeground(for scheme: ColorScheme) -> Color {
        guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) else { return .white }
        var lum: Double = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let nc = NSColor(self).usingColorSpace(.genericRGB) else { return }
            lum = 0.2126 * nc.redComponent + 0.7152 * nc.greenComponent + 0.0722 * nc.blueComponent
        }
        return lum > 0.35 ? Color.black.opacity(0.85) : .white
    }

    /// The foreground color for a static (non-adaptive) color — same WCAG logic
    /// without an appearance context. Use for colors built from explicit RGB/HSB values.
    var contrastingForeground: Color {
        guard let nc = NSColor(self).usingColorSpace(.genericRGB) else { return .white }
        let lum = 0.2126 * nc.redComponent + 0.7152 * nc.greenComponent + 0.0722 * nc.blueComponent
        return lum > 0.35 ? Color.black.opacity(0.85) : .white
    }
}
