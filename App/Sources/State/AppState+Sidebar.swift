import ADBKit
import Foundation

/// Sidebar, launchpad, catalog, and menu-bar derivation plus the layout
/// customization that drives them (enable/disable, reorder, group, pin,
/// menu-bar selection). Split out of AppState to keep that core focused on the
/// device/selection state machine; these all read/write `layout` and never the
/// `private(set)` selection setters, so they live cleanly in an extension.
extension AppState {
    /// Enabled features shown on the sidebar, in display order (registry order
    /// within categories). Hub members are excluded — they're managed from
    /// their hub screen, never as standalone sidebar rows — but stay reachable
    /// via search (`disabledMatches`) and hotkeys.
    var enabledFeatures: [FeatureDef] {
        let enabled = layout.effectiveEnabledIDs
        return FeatureRegistry.all.filter { enabled.contains($0.id) && !$0.isAbsorbedByHub }
    }

    /// The launchpad grid: the role-curated enabled set in its curated order,
    /// re-ranked by real usage (most-used first), with the curated order as the
    /// stable fallback. Hub members stay excluded, exactly like the sidebar.
    var launchpadFeatures: [FeatureDef] {
        let curated = ordered(enabledFeatures)
        let byID = Dictionary(uniqueKeysWithValues: curated.map { ($0.id, $0) })
        return usageStats.rank(curated.map(\.id)).compactMap { byID[$0] }
    }

    var visibleFeatures: [FeatureDef] {
        enabledFeatures.filter { $0.matches(searchText) }
    }

    /// Sorts features by the user's custom order (`sidebarOrder`), registry
    /// order as the tiebreak. Shared by the grouped/ungrouped sidebar and the
    /// catalog so every surface reflects the same reordering.
    private func ordered(_ features: [FeatureDef]) -> [FeatureDef] {
        let order = layout.sidebarOrder ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let registryIndex = Dictionary(
            uniqueKeysWithValues: FeatureRegistry.all.enumerated().map { ($1.id, $0) }
        )
        return features.sorted {
            (rank[$0.id] ?? Int.max, registryIndex[$0.id] ?? 0)
                < (rank[$1.id] ?? Int.max, registryIndex[$1.id] ?? 0)
        }
    }

    /// Categories in the user's order (`categoryOrder`), display order as the
    /// fallback and tiebreak.
    var orderedCategories: [FeatureCategory] {
        let order = layout.categoryOrder ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let displayIndex = Dictionary(
            uniqueKeysWithValues: FeatureCategory.displayOrder.enumerated().map { ($1.rawValue, $0) }
        )
        return FeatureCategory.displayOrder.sorted {
            (rank[$0.rawValue] ?? Int.max, displayIndex[$0.rawValue] ?? 0)
                < (rank[$1.rawValue] ?? Int.max, displayIndex[$1.rawValue] ?? 0)
        }
    }

    /// Enabled, non-pinned features in `category`, in the user's order — the
    /// contents of one grouped-sidebar section.
    func enabledFeatures(in category: FeatureCategory) -> [FeatureDef] {
        ordered(enabledFeatures.filter { $0.category == category && !layout.favorites.contains($0.id) })
    }

    /// The feature rows actually rendered for a group — empty when collapsed, so
    /// a collapsed group is a single header row (and reordering collapsed groups
    /// shows the drop guideline only at group boundaries).
    func shownFeatures(in category: FeatureCategory) -> [FeatureDef] {
        isCategoryCollapsed(category) ? [] : enabledFeatures(in: category)
    }

    /// Categories rendered in the grouped sidebar: those with ≥1 enabled
    /// feature, in the user's order (collapsed ones still show their header).
    var sidebarCategories: [FeatureCategory] {
        orderedCategories.filter { !enabledFeatures(in: $0).isEmpty }
    }

    func isCategoryCollapsed(_ category: FeatureCategory) -> Bool {
        layout.collapsedCategories?.contains(category.rawValue) ?? false
    }

    func toggleCategoryCollapsed(_ category: FeatureCategory) {
        var collapsed = layout.collapsedCategories ?? []
        if let index = collapsed.firstIndex(of: category.rawValue) {
            collapsed.remove(at: index)
        } else {
            collapsed.append(category.rawValue)
        }
        layout.collapsedCategories = collapsed
        persistLayout()
    }

    /// Every catalog feature in `category` (enabled or not), in the user's
    /// order — the contents of one catalog section.
    func catalogFeatures(in category: FeatureCategory) -> [FeatureDef] {
        ordered(FeatureRegistry.all.filter { $0.category == category && !$0.isAbsorbedByHub })
    }

    /// Enabled, non-pinned features in grouped display order, flattened — the
    /// seed for the flat sidebar before the user reorders it.
    private var groupedFlatFeatures: [FeatureDef] {
        orderedCategories.flatMap { enabledFeatures(in: $0) }
    }

    /// Enabled, non-pinned features in the flat sidebar's own order. Until the
    /// user reorders the flat list (`flatOrder` is nil), it mirrors the grouped
    /// order so toggling grouping off doesn't reshuffle anything.
    var orderedEnabledFeatures: [FeatureDef] {
        guard let flatOrder = layout.flatOrder else { return groupedFlatFeatures }
        let rank = Dictionary(flatOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let registryIndex = Dictionary(
            uniqueKeysWithValues: FeatureRegistry.all.enumerated().map { ($1.id, $0) }
        )
        return enabledFeatures.filter { !layout.favorites.contains($0.id) }.sorted {
            (rank[$0.id] ?? Int.max, registryIndex[$0.id] ?? 0)
                < (rank[$1.id] ?? Int.max, registryIndex[$1.id] ?? 0)
        }
    }

    /// Genuinely-disabled features — not on the sidebar and not folded into a
    /// hub — that match the current search, shown in their own section so
    /// they're runnable or openable without enabling. Hub members are excluded:
    /// they're used from their hub, which carries their keywords and surfaces
    /// for the same searches, so listing them as "disabled" would mislead.
    var disabledMatches: [FeatureDef] {
        let shown = Set(enabledFeatures.map(\.id))
        return FeatureRegistry.all.filter {
            !shown.contains($0.id) && !$0.isAbsorbedByHub && $0.matches(searchText)
        }
    }

    /// Catalog features not currently on the sidebar — drives the "+N more
    /// features" label, so it counts only what the catalog can actually toggle
    /// (hub members aren't in the catalog).
    var hiddenFeatureCount: Int {
        FeatureRegistry.catalogFeatureIDs.count - enabledFeatures.count
    }

    /// Enabled features in the exact order the sidebar shows them — pinned
    /// first, then grouped by category or the user's drag order — ignoring any
    /// active search. Lets the Hotkeys settings list mirror the sidebar instead
    /// of dumping the full registry.
    var sidebarFeatures: [FeatureDef] {
        let grouped = UserDefaults.standard.object(forKey: "groupSidebar") as? Bool ?? true
        let pinned = ordered(enabledFeatures.filter { layout.favorites.contains($0.id) })
        let rest = grouped
            ? orderedCategories.flatMap { enabledFeatures(in: $0) }
            : orderedEnabledFeatures
        return pinned + rest
    }

    // MARK: - Layout (catalog customization)

    func setFeatureEnabled(_ featureID: String, enabled: Bool) {
        var ids = layout.effectiveEnabledIDs
        if enabled {
            ids.insert(featureID)
        } else {
            ids.remove(featureID)
        }
        layout.enabledIds = FeatureRegistry.all.map(\.id).filter { ids.contains($0) }
        persistLayout()
    }

    /// Reorder a displayed list of features — a grouped-sidebar/catalog section
    /// or the flat sidebar — writing the result back into the global
    /// `sidebarOrder` so the other groups keep their positions. `displayed` is
    /// exactly the list the reordered `ForEach` showed.
    func reorderFeatures(_ displayed: [FeatureDef], from source: IndexSet, to destination: Int) {
        layout.sidebarOrder = SidebarOrdering.reorder(
            displayed: displayed.map(\.id), from: source, to: destination,
            within: ordered(FeatureRegistry.all).map(\.id)
        )
        persistLayout()
    }

    /// Reorder the flat (ungrouped) sidebar. `displayed` is the whole flat list,
    /// so the moved sequence is stored verbatim as the independent `flatOrder` —
    /// leaving the grouped order (`sidebarOrder`/`categoryOrder`) untouched.
    func reorderFlatFeatures(_ displayed: [FeatureDef], from source: IndexSet, to destination: Int) {
        let ids = displayed.map(\.id)
        layout.flatOrder = SidebarOrdering.reorder(displayed: ids, from: source, to: destination, within: ids)
        persistLayout()
    }

    /// Move a feature to `toIndex` within its group (sidebar drag-and-drop).
    /// `toIndex` is the insertion position in the group's enabled-feature list
    /// (0 = top, count = end).
    func moveFeature(_ id: String, toIndex: Int, in category: FeatureCategory) {
        let group = enabledFeatures(in: category)
        guard let from = group.firstIndex(where: { $0.id == id }) else { return }
        reorderFeatures(group, from: IndexSet(integer: from), to: toIndex)
    }

    /// Move a feature to `toIndex` within the flat (ungrouped) sidebar, writing
    /// the independent `flatOrder`. `toIndex` is the insertion position in the
    /// flat list (0 = top, count = end).
    func moveFlatFeature(_ id: String, toIndex: Int) {
        let flat = orderedEnabledFeatures
        guard let from = flat.firstIndex(where: { $0.id == id }) else { return }
        reorderFlatFeatures(flat, from: IndexSet(integer: from), to: toIndex)
    }

    /// Move a whole group before `targetRawValue` (nil = to the end).
    func moveGroup(_ rawValue: String, before targetRawValue: String?) {
        let full = orderedCategories.map(\.rawValue)
        layout.categoryOrder = targetRawValue.map { SidebarOrdering.move(rawValue, before: $0, in: full) }
            ?? SidebarOrdering.moveToEnd(rawValue, in: full)
        persistLayout()
    }

    // MARK: - Group enable/disable

    /// Toggleable features in a category — excludes hub members (managed from
    /// their hub) and system features (can't be disabled).
    private func toggleableFeatures(in category: FeatureCategory) -> [FeatureDef] {
        FeatureRegistry.all.filter {
            $0.category == category && !$0.isAbsorbedByHub && $0.kind != .system
        }
    }

    /// Whether a category has any feature the user can enable/disable — the
    /// group toggle is hidden for groups that don't (e.g. a system-only group).
    func canToggleGroup(_ category: FeatureCategory) -> Bool {
        !toggleableFeatures(in: category).isEmpty
    }

    /// True when at least one toggleable feature in the category is enabled —
    /// the group's "disable all" affordance is offered while this holds.
    func isGroupEnabled(_ category: FeatureCategory) -> Bool {
        toggleableFeatures(in: category).contains { layout.effectiveEnabledIDs.contains($0.id) }
    }

    /// Enable or disable every toggleable feature in the category at once.
    func setGroupEnabled(_ category: FeatureCategory, enabled: Bool) {
        var ids = layout.effectiveEnabledIDs
        for feature in toggleableFeatures(in: category) {
            if enabled { ids.insert(feature.id) } else { ids.remove(feature.id) }
        }
        layout.enabledIds = FeatureRegistry.all.map(\.id).filter { ids.contains($0) }
        persistLayout()
    }

    func toggleFavorite(_ featureID: String) {
        if let index = layout.favorites.firstIndex(of: featureID) {
            layout.favorites.remove(at: index)
        } else {
            layout.favorites.append(featureID)
        }
        persistLayout()
    }

    func persistLayout() {
        let snapshot = layout
        Task {
            try? await env.stores.layout.save(snapshot)
        }
    }

    // MARK: - Menu bar

    /// Features shown in the menu-bar menu: the user's explicit choice, else
    /// pinned features, else the enabled instant actions (excluding the two
    /// always-on quick actions).
    var menuBarFeatures: [FeatureDef] {
        if let chosen = layout.menuBarItems, !chosen.isEmpty {
            return chosen.compactMap { FeatureRegistry.byID[$0] }
        }
        let favorites = layout.favorites.compactMap { FeatureRegistry.byID[$0] }
        if !favorites.isEmpty { return favorites }
        return enabledFeatures.filter {
            $0.kind == .instantAction && $0.id != "screenshot" && $0.id != "scrcpy"
        }
    }

    func isInMenuBar(_ featureID: String) -> Bool {
        layout.menuBarItems?.contains(featureID) ?? false
    }

    func setMenuBarItem(_ featureID: String, included: Bool) {
        var items = layout.menuBarItems ?? []
        if included {
            if !items.contains(featureID) { items.append(featureID) }
        } else {
            items.removeAll { $0 == featureID }
        }
        layout.menuBarItems = items
        persistLayout()
    }
}
