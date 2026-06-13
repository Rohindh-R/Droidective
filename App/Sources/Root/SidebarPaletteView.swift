import ADBKit
import SwiftUI

/// Raycast-style command palette: pinned search field on top of the
/// categorized feature list. ⌘K focuses search from anywhere; ↑/↓ move the
/// selection from the field; ⏎ runs instant actions straight away.
struct SidebarPaletteView: View {
    @Environment(AppState.self) private var state
    @FocusState private var searchFocused: Bool
    @AppStorage("showFrequent") private var showFrequent = true

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            TextField("Filter features…", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .onSubmit { runTopMatch() }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }

            List(selection: $state.selectedFeatureID) {
                let visible = state.visibleFeatures
                let favorites = visible.filter { state.layout.favorites.contains($0.id) }

                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { feature in
                            FeatureRowView(feature: feature)
                        }
                    }
                }

                if state.searchText.isEmpty && showFrequent {
                    let frequent = state.frequentFeatures
                    if !frequent.isEmpty {
                        Section("Frequent") {
                            ForEach(frequent) { feature in
                                FeatureRowView(feature: feature)
                            }
                        }
                    }
                }

                ForEach(FeatureCategory.displayOrder, id: \.self) { category in
                    let features = visible.filter {
                        $0.category == category && !state.layout.favorites.contains($0.id)
                    }
                    if !features.isEmpty {
                        Section(category.label) {
                            ForEach(features) { feature in
                                FeatureRowView(feature: feature)
                            }
                        }
                    }
                }

                // Disabled features surface only while searching — usable
                // from here without appearing on the home list.
                if !state.searchText.isEmpty {
                    let disabled = state.disabledMatches
                    if !disabled.isEmpty {
                        Section("Disabled") {
                            ForEach(disabled) { feature in
                                FeatureRowView(feature: feature, dimmed: true)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button {
                    state.selectedFeatureID = "catalog"
                } label: {
                    Label(
                        state.hiddenFeatureCount > 0
                            ? "+ \(state.hiddenFeatureCount) more features"
                            : "Manage features",
                        systemImage: "square.grid.2x2"
                    )
                    .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (⌘,)")
            }
            .padding(8)
        }
        .onChange(of: state.focusSearchToken) {
            searchFocused = true
        }
        .onChange(of: state.selectedFeatureID) {
            state.persistLastFeature()
        }
    }

    /// All rows in display order, for keyboard navigation and ⏎-to-run.
    private var orderedMatches: [FeatureDef] {
        let visible = state.visibleFeatures
        let favorites = visible.filter { state.layout.favorites.contains($0.id) }
        let frequent = state.searchText.isEmpty ? state.frequentFeatures : []
        let rest = visible.filter { feature in
            !favorites.contains(where: { $0.id == feature.id })
                && !frequent.contains(where: { $0.id == feature.id })
        }
        let disabled = state.searchText.isEmpty ? [] : state.disabledMatches
        return favorites + frequent + rest + disabled
    }

    /// ⏎ in the search field: run the top instant action immediately, or
    /// open the top match's detail.
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
    let feature: FeatureDef
    var dimmed = false

    var body: some View {
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
        .opacity(dimmed ? 0.75 : 1)
        .tag(feature.id)
        .padding(.vertical, 1)
    }
}
