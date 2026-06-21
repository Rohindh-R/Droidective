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
    static var brandAccent: Color { Color("BrandAccent") }
}
