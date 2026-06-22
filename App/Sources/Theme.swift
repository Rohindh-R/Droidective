import SwiftUI

/// App color tokens — the single source of truth for every color in the UI.
/// The "Terminal" (dark) / "Lab" (light) palette, sourced from the asset catalog
/// with a light + dark variant per token. To re-theme the whole app, edit the
/// matching `*.colorset` in `Assets.xcassets` (or point a token at a different
/// asset here) — no view code changes.
///
/// These are *named* asset colors, not the system accent. A named asset color
/// resolves statically and keeps its value when the window goes inactive,
/// whereas `.tint` / `Color.accentColor` follow the user's macOS accent and
/// desaturate to graphite on focus loss. So every icon, label, fill, and chart
/// series colors itself from a token here rather than a system/literal color.
///
/// Icon usage (the matrix): static-navigation and input icons are `.textMuted`;
/// resting-action icons inherit `.textMain`; active/selected icons, loaders, and
/// CTAs are `.brandAccent`.
extension ShapeStyle where Self == Color {
    // MARK: Surfaces
    /// Deepest layer — the content background (the "graphite case").
    static var bgRoot: Color { Color("BgRoot") }
    /// Lifted surface — sidebar, cards, and bars sit one step above `bgRoot`.
    static var bgSurface: Color { Color("BgSurface") }
    /// Thin dividers, borders, and faint neutral fills.
    static var borderSubtle: Color { Color("BorderSubtle") }

    // MARK: Content
    /// Primary reading text, header titles, active values, resting-action icons.
    static var textMain: Color { Color("TextMain") }
    /// Subtitles, timestamps, labels, and quiet navigation/input icons.
    static var textMuted: Color { Color("TextMuted") }
    /// The faintest text/icons — hints, captions, placeholders.
    static var textFaint: Color { Color("TextFaint") }

    // MARK: Accent
    /// "The electricity" — CTAs, active toggles, selection, loaders, logo mark.
    static var brandAccent: Color { Color("BrandAccent") }

    // MARK: Status
    /// Positive / ready / completed — connected device, OK result, exit code 0.
    static var success: Color { Color("Success") }
    /// Heads-up — overrides active, unauthorized device, pinned, disabled app.
    static var warning: Color { Color("Warning") }
    /// Error / destructive — failed result, delete, disconnect, error badge.
    static var danger: Color { Color("Danger") }

    // MARK: Data viz
    /// Categorical chart/metric palette. Distinct hues for legibility; the
    /// positive series (RAM, Upload) uses `.brandAccent`. 1: blue, 2: teal,
    /// 3: violet, 4: amber.
    static var chart1: Color { Color("Chart1") }
    static var chart2: Color { Color("Chart2") }
    static var chart3: Color { Color("Chart3") }
    static var chart4: Color { Color("Chart4") }
}
