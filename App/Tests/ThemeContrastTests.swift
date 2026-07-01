import AppKit
import SwiftUI
import Testing

/// `Color.contrastingForeground` picks readable text over a colored background via
/// a luminance threshold. The math is pure decision logic with a magic constant,
/// so it's pinned here rather than left to be eyeballed on-screen.
@Suite struct ThemeContrastTests {
    /// Resolves the result to whether it's the near-black ("dark text") branch
    /// rather than white, by reading its red component in sRGB.
    private func isDarkText(_ color: Color) -> Bool {
        (NSColor(color).usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5
    }

    @Test func lightBackgroundGetsDarkText() {
        #expect(isDarkText(Color.white.contrastingForeground))
        #expect(isDarkText(Color.white.contrastingForeground(for: .light)))
    }

    @Test func darkBackgroundGetsLightText() {
        #expect(!isDarkText(Color.black.contrastingForeground))
        #expect(!isDarkText(Color.black.contrastingForeground(for: .dark)))
    }

    @Test func brightGreenIsAboveThresholdSoGetsDarkText() {
        // Pure green: luminance ≈ 0.715, well above the 0.35 threshold.
        #expect(isDarkText(Color(.sRGB, red: 0, green: 1, blue: 0).contrastingForeground))
    }

    @Test func pureBlueIsBelowThresholdSoGetsLightText() {
        // Pure blue: luminance ≈ 0.072, below the threshold.
        #expect(!isDarkText(Color(.sRGB, red: 0, green: 0, blue: 1).contrastingForeground))
    }

    @Test func adaptiveVariantResolvesForEachScheme() {
        let nearWhite = Color(.sRGB, red: 0.95, green: 0.95, blue: 0.95)
        #expect(isDarkText(nearWhite.contrastingForeground(for: .light)))
        let nearBlack = Color(.sRGB, red: 0.05, green: 0.05, blue: 0.05)
        #expect(!isDarkText(nearBlack.contrastingForeground(for: .dark)))
    }
}
