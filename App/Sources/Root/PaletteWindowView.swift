import ADBKit
import AppKit
import SwiftUI

/// Spotlight-style floating search palette (⌘K): type, arrow through matches,
/// ⏎ opens the feature in the main window. ⌘P pins / ⌘E enables-disables the
/// highlighted feature. Pinned features lead the list when not searching. Esc
/// closes.
struct PaletteWindowView: View {
    @Environment(AppState.self) private var state

    let onClose: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private static let digitKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8"]

    private var searching: Bool { !query.isEmpty }

    /// Results in display order. When not searching, pinned features lead; once
    /// the user types, the pinned section drops and results rank by relevance.
    private var matches: [FeatureDef] {
        let enabled = state.layout.effectiveEnabledIDs
        if searching {
            let ranked = FeatureRegistry.all.enumerated()
                .filter { $0.element.matches(query) && !$0.element.isAbsorbedByHub }
                .sorted { lhs, rhs in
                    let rl = lhs.element.relevance(for: query)
                    let rr = rhs.element.relevance(for: query)
                    return rl != rr ? rl > rr : lhs.offset < rhs.offset
                }
                .map(\.element)
            return ranked.filter { enabled.contains($0.id) } + ranked.filter { !enabled.contains($0.id) }
        }
        let pinned = state.layout.favorites
            .compactMap { FeatureRegistry.byID[$0] }
            .filter { !$0.isAbsorbedByHub }
        let pinnedIDs = Set(pinned.map(\.id))
        let rest = FeatureRegistry.all.filter { !$0.isAbsorbedByHub && !pinnedIDs.contains($0.id) }
        return pinned
            + rest.filter { enabled.contains($0.id) }
            + rest.filter { !enabled.contains($0.id) }
    }

    private var visibleMatches: [FeatureDef] { Array(matches.prefix(8)) }

    private var highlightedFeature: FeatureDef? {
        visibleMatches.indices.contains(highlighted) ? visibleMatches[highlighted] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if !visibleMatches.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(visibleMatches.enumerated()), id: \.element.id) { index, feature in
                        paletteRow(feature, index: index, isHighlighted: index == highlighted)
                            .onTapGesture { open(at: index) }
                    }
                }
                .padding(6)
                Divider()
                footer
            } else if !query.isEmpty {
                Divider()
                Text("No matching features")
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .padding(14)
            }
        }
        .frame(width: 520)
        // Borderless window has no title bar and a clear backing, so the content
        // sizes the window exactly — flush at top and bottom. The material is the
        // content's own background, clipped to rounded corners.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background { shortcutButtons }
        .onExitCommand { close() }
        .onAppear {
            query = ""
            highlighted = 0
            // Focus must land after the panel becomes key — setting it
            // synchronously in onAppear loses the race.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                fieldFocused = true
            }
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.textMuted)
            TextField("Search features…", text: $query)
                .textFieldStyle(.plain)
                .font(.title)
                .focused($fieldFocused)
                .onSubmit { open(at: highlighted) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// Hidden buttons backing the palette's keyboard shortcuts: ⌘1–8 jump,
    /// ⌘P pin/unpin, ⌘E enable/disable — all acting on the highlighted row.
    private var shortcutButtons: some View {
        ZStack {
            ForEach(Array(Self.digitKeys.enumerated()), id: \.offset) { index, key in
                Button("") { open(at: index) }
                    .keyboardShortcut(key, modifiers: .command)
            }
            Button("") { togglePinHighlighted() }.keyboardShortcut("p", modifiers: .command)
            Button("") { toggleEnabledHighlighted() }.keyboardShortcut("e", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private var footer: some View {
        let pinned = highlightedFeature.map { state.layout.favorites.contains($0.id) } ?? false
        let isEnabled = highlightedFeature.map { state.layout.effectiveEnabledIDs.contains($0.id) } ?? true
        return HStack(spacing: 14) {
            footerHint("⏎", "Open")
            footerHint("⌘P", pinned ? "Unpin" : "Pin")
            if highlightedFeature?.kind != .system {
                footerHint("⌘E", isEnabled ? "Disable" : "Enable")
            }
            Spacer()
            footerHint("⌘1–8", "Jump")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyHint(key)
            Text(label).font(.caption2).foregroundStyle(.textMuted)
        }
    }

    private func paletteRow(_ feature: FeatureDef, index: Int, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feature.icon)
                .frame(width: 22)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.brandAccent))
            VStack(alignment: .leading, spacing: 0) {
                Text(feature.title)
                if let subtitle = feature.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if state.layout.favorites.contains(feature.id) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.brandAccent))
            }
            if !state.layout.effectiveEnabledIDs.contains(feature.id) {
                Text("disabled")
                    .font(.caption2)
                    .foregroundStyle(isHighlighted ? .white.opacity(0.75) : .secondary)
            }
            if index < 8 {
                KeyHint("⌘\(index + 1)", prominent: isHighlighted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isHighlighted ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(isHighlighted ? .white : .primary)
        .contentShape(Rectangle())
    }

    private func move(_ offset: Int) {
        let count = visibleMatches.count
        guard count > 0 else { return }
        highlighted = (highlighted + offset + count) % count
    }

    private func open(at index: Int) {
        guard visibleMatches.indices.contains(index) else { return }
        let feature = visibleMatches[index]
        close()
        state.activateMainWindow()
        state.requestFeature(feature.id)
    }

    private func togglePinHighlighted() {
        guard let feature = highlightedFeature else { return }
        state.toggleFavorite(feature.id)
    }

    private func toggleEnabledHighlighted() {
        guard let feature = highlightedFeature, feature.kind != .system else { return }
        state.setFeatureEnabled(feature.id, enabled: !state.layout.effectiveEnabledIDs.contains(feature.id))
    }

    private func close() {
        onClose()
    }
}

/// A small keycap-style hint badge (e.g. ⌘K, ⌘1). `prominent` styles it for a
/// highlighted/accent background.
struct KeyHint: View {
    let text: String
    var prominent = false

    init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.textMuted))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                prominent ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }
}
