import SwiftUI

extension View {
    /// Sparse, single-purpose content — an action button, a toggle, a compact
    /// readout. Grounds the content in a card that hugs it and centers the card
    /// in the available space: vertically centered when it fits, scrollable when
    /// it overflows. The card sizes to its content, so a one-field action reads
    /// as a snug panel rather than a lonely control in an oversized box.
    func centeredCard() -> some View {
        modifier(CenteredCardModifier())
    }

    /// A structured grouped `Form` (multi-section settings). Capped to a
    /// comfortable reading width and centered horizontally so it doesn't
    /// stretch edge to edge; the form keeps its own vertical scrolling.
    func centeredColumn(maxWidth: CGFloat = 560) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

private struct CenteredCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            ScrollView {
                content
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.bgSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.borderSubtle, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .frame(minHeight: geo.size.height)
            }
        }
    }
}
