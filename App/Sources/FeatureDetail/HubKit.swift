import SwiftUI

/// Building blocks for hub / multi-section screens (Connection, Wireless ADB,
/// Private DNS, and future hubs). They replace the macOS grouped `Form` — whose
/// inset bars, wide leading gutter, and right-aligned value rows read as busy
/// and ambiguous — with a uniform, scannable card layout.

/// A titled content card: a header (title + optional one-line subtitle) above
/// its controls, on a single lifted surface. The consistent container for every
/// section, so the whole screen reads as one rhythm instead of mismatched bars.
struct HubSection<Content: View>: View {
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.textMain)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.bgSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.borderSubtle, lineWidth: 1))
    }
}

/// A labeled text input: a quiet caption above a brand-focus field, so a field
/// always reads as "type here" rather than a static value row.
struct HubField: View {
    private let label: String
    private let prompt: String?
    @Binding private var text: String

    init(_ label: String, prompt: String? = nil, text: Binding<String>) {
        self.label = label
        self.prompt = prompt
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.textMuted)
            TextField("", text: $text, prompt: prompt.map(Text.init))
                .brandField()
                .labelsHidden()
        }
    }
}

/// The standard scrollable, centered column that holds a screen's `HubSection`s
/// — a readable max width so content never sprawls across the pane or strands
/// in a side gutter.
struct HubColumn<Content: View>: View {
    @ViewBuilder private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A read-only label / value row for data inside a `HubSection` (e.g. device
/// properties) — label at the leading edge, selectable value trailing.
struct HubRow: View {
    private let label: String
    private let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.textMain)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.textMuted)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
