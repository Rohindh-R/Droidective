import ADBKit
import AppKit
import KeyboardShortcuts
import SwiftUI

/// Raycast-style command palette: pinned search field on top of the
/// categorized feature list. ⌘K focuses search from anywhere; ↑/↓ move the
/// selection from the field; ⏎ runs instant actions straight away. With the
/// search field focused, holding ⌘ shows ⌘1–⌘9 badges on the first nine rows
/// and ⌘<n> jumps to that row.
struct SidebarPaletteView: View {
    @Environment(AppState.self) private var state
    @FocusState private var searchFocused: Bool
    @AppStorage("groupSidebar") private var groupSidebar = true
    @State private var commandHeld = false
    @State private var flagsMonitor: Any?
    /// Whether this window is the active (key) one — the ⌘ flags monitor fires
    /// app-wide, so without this the ⌘1–9 hints appear even when Settings or
    /// another window holds focus.
    @Environment(\.controlActiveState) private var controlActive

    private static let digitKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            TextField("Search features…", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.title3)
                .focused($searchFocused)
                .overlay(alignment: .trailing) {
                    if state.searchText.isEmpty {
                        KeyHint("⌘K")
                            .padding(.trailing, 6)
                            .allowsHitTesting(false)
                            .help("⌘K opens the full search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .onSubmit { runTopMatch() }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }

            List(selection: $state.selectedFeatureID) {
                let visible = state.visibleFeatures
                let pinned = visible.filter { state.layout.favorites.contains($0.id) }
                // ⌘1–⌘9 hints: id → 0-based rank, only while search is focused
                // and ⌘ is held. Order matches the rows top-to-bottom.
                let shortcutRank = (searchFocused && commandHeld && controlActive == .key)
                    ? Dictionary(
                        orderedMatches.prefix(9).enumerated().map { ($1.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    : [:]

                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { feature in
                            FeatureRowView(feature: feature, shortcutIndex: shortcutRank[feature.id])
                        }
                    }
                }

                let rest = visible.filter { !state.layout.favorites.contains($0.id) }
                if !state.searchText.isEmpty {
                    // Searching: one flat list ranked by relevance (best match
                    // first), so "app" surfaces Apps before Deep Links.
                    Section {
                        ForEach(ranked(rest)) { feature in
                            FeatureRowView(feature: feature, shortcutIndex: shortcutRank[feature.id])
                        }
                    }
                } else if groupSidebar {
                    ForEach(FeatureCategory.displayOrder, id: \.self) { category in
                        let features = rest.filter { $0.category == category }
                        if !features.isEmpty {
                            Section(category.label) {
                                ForEach(features) { feature in
                                    FeatureRowView(feature: feature, shortcutIndex: shortcutRank[feature.id])
                                }
                            }
                        }
                    }
                } else {
                    // Ungrouped: the user's custom order, drag to reorder.
                    Section {
                        ForEach(state.orderedEnabledFeatures) { feature in
                            FeatureRowView(feature: feature, shortcutIndex: shortcutRank[feature.id])
                        }
                        .onMove { source, destination in
                            state.moveFeature(from: source, to: destination)
                        }
                    }
                }

                // Disabled features surface only while searching — usable from
                // here without appearing on the home list.
                if !state.searchText.isEmpty {
                    let disabled = ranked(state.disabledMatches)
                    if !disabled.isEmpty {
                        Section("Disabled") {
                            ForEach(disabled) { feature in
                                FeatureRowView(feature: feature, shortcutIndex: shortcutRank[feature.id], dimmed: true)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            bottomBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background { shortcutButtons }
        .onChange(of: state.focusSearchToken) { searchFocused = true }
        .onChange(of: state.selectedFeatureID) { state.persistLastFeature() }
        .onAppear {
            // Track ⌘ so the row hints can appear/disappear as it's held.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                commandHeld = event.modifierFlags.contains(.command)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                state.selectedFeatureID = "home"
            } label: {
                Image(systemName: "house")
                    .font(.title2)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.selectedFeatureID == "home" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help("Home — overview & getting started")

            Button {
                state.selectedFeatureID = "catalog"
            } label: {
                Label(
                    state.hiddenFeatureCount > 0 ? "+ \(state.hiddenFeatureCount) more features" : "Manage features",
                    systemImage: "square.grid.2x2"
                )
                .font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.selectedFeatureID == "catalog" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Spacer()

            Button {
                state.selectedFeatureID = "about"
            } label: {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.selectedFeatureID == "about" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help("About & Feedback — version, report an issue, star on GitHub")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Hidden ⌘1–⌘9 accelerators, active only while the search field is
    /// focused — each jumps to the matching numbered row.
    private var shortcutButtons: some View {
        ForEach(Array(Self.digitKeys.enumerated()), id: \.offset) { index, key in
            Button("") { activate(index) }
                .keyboardShortcut(key, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .disabled(!searchFocused)
        }
    }

    /// All rows in display order (Pinned → grouped/flat body → Disabled), for
    /// keyboard navigation, ⏎, and the ⌘1–9 hints.
    private var orderedMatches: [FeatureDef] {
        let visible = state.visibleFeatures
        let pinned = visible.filter { state.layout.favorites.contains($0.id) }
        let rest = visible.filter { !state.layout.favorites.contains($0.id) }
        let body: [FeatureDef]
        if !state.searchText.isEmpty {
            body = ranked(rest)
        } else if groupSidebar {
            body = FeatureCategory.displayOrder.flatMap { category in
                rest.filter { $0.category == category }
            }
        } else {
            body = state.orderedEnabledFeatures
        }
        let disabled = state.searchText.isEmpty ? [] : ranked(state.disabledMatches)
        return pinned + body + disabled
    }

    /// Search results ranked by relevance (best first), registry order as the
    /// tiebreak. `features` arrive in registry order, so `offset` is stable.
    private func ranked(_ features: [FeatureDef]) -> [FeatureDef] {
        let query = state.searchText
        return features.enumerated().sorted { lhs, rhs in
            let rl = lhs.element.relevance(for: query)
            let rr = rhs.element.relevance(for: query)
            return rl != rr ? rl > rr : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func activate(_ index: Int) {
        let matches = orderedMatches
        guard matches.indices.contains(index) else { return }
        state.selectedFeatureID = matches[index].id
        searchFocused = false
    }

    /// ⏎ in the search field: run the top instant action immediately, or open
    /// the top match's detail.
    private func runTopMatch() {
        let target = orderedMatches.first { $0.id == state.selectedFeatureID } ?? orderedMatches.first
        guard let target else { return }
        state.selectedFeatureID = target.id
        if target.kind == .instantAction {
            Task { await state.run(feature: target, params: [:]) }
        } else {
            searchFocused = false
        }
    }

    private func moveSelection(by offset: Int) {
        let matches = orderedMatches
        guard !matches.isEmpty else { return }
        let currentIndex = matches.firstIndex { $0.id == state.selectedFeatureID }
        let next = ((currentIndex ?? -1) + offset + matches.count) % matches.count
        state.selectedFeatureID = matches[next].id
    }
}

struct FeatureRowView: View {
    @Environment(AppState.self) private var state
    let feature: FeatureDef
    /// 0-based ⌘<n> hint to show trailing (nil = none).
    var shortcutIndex: Int?
    var dimmed = false
    @State private var showingHotkey = false

    private var isPinned: Bool { state.layout.favorites.contains(feature.id) }
    private var isEnabled: Bool { state.layout.effectiveEnabledIDs.contains(feature.id) }

    var body: some View {
        HStack(spacing: 0) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(feature.title)
                        .lineLimit(1)
                    if let subtitle = feature.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: feature.icon)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            if let shortcutIndex {
                Spacer(minLength: 6)
                KeyHint("⌘\(shortcutIndex + 1)")
            }
        }
        .opacity(dimmed ? 0.75 : 1)
        .tag(feature.id)
        .padding(.vertical, 1)
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
                state.toggleFavorite(feature.id)
            }
            if feature.kind != .system {
                Button(isEnabled ? "Disable" : "Enable", systemImage: isEnabled ? "eye.slash" : "eye") {
                    state.setFeatureEnabled(feature.id, enabled: !isEnabled)
                }
            }
            Divider()
            Button("Set Hotkey…", systemImage: "keyboard") {
                showingHotkey = true
            }
        }
        .popover(isPresented: $showingHotkey, arrowEdge: .trailing) {
            HotkeyPopover(feature: feature)
        }
    }
}

/// Inline global-hotkey recorder reached from a sidebar row's right-click menu.
/// Shows a live preview of the modifiers being held (press ⌘ and "⌘ …" appears
/// immediately, before the full combo lands) above the recorder. Writes the
/// same KeyboardShortcuts name the Hotkeys settings tab uses, so they stay in
/// sync.
private struct HotkeyPopover: View {
    let feature: FeatureDef
    @State private var held = NSEvent.ModifierFlags()
    @State private var flagsMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hotkey · \(feature.title)")
                .font(.headline)
            preview
            KeyboardShortcuts.Recorder("", name: HotkeyManager.featureName(feature.id))
            Text("Global — fires even when Droidective is in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }

    private var preview: some View {
        let symbols = HotkeyManager.symbolString(for: held)
        return HStack {
            if symbols.isEmpty {
                Text("Hold ⌘ / ⌥ / ⌃ / ⇧, then a key")
                    .foregroundStyle(.secondary)
            } else {
                Text(symbols + " …")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
