import SwiftUI

/// Building blocks for hub / multi-section screens (Connection, Wireless ADB,
/// Private DNS, and future hubs). They replace the macOS grouped `Form` — whose
/// inset bars, wide leading gutter, and right-aligned value rows read as busy
/// and ambiguous — with a uniform, scannable card layout.

/// A titled content card: a header (title + optional one-line subtitle) above
/// its controls, on a single lifted surface. The consistent container for every
/// section, so the whole screen reads as one rhythm instead of mismatched bars.
struct HubSection<Content: View, Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let accessory: () -> Accessory
    @ViewBuilder private let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content)
        where Accessory == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { EmptyView() }
        self.content = content
    }

    /// Variant with a trailing accessory in the header (e.g. a refresh button).
    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.textMain)
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.bgSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    colorScheme == .light ? Color.black.opacity(0.14) : .borderSubtle,
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(colorScheme == .light ? 0.12 : 0), radius: 8, x: 0, y: 2)
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

/// A divider-separated list of label/value `HubRow`s — the read-only data block
/// inside a `HubSection` (device properties, app info, …).
struct HubRowList: View {
    private let rows: [(String, String)]

    init(_ rows: [(String, String)]) { self.rows = rows }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HubRow(row.0, row.1).padding(.vertical, 7)
            }
        }
    }
}
