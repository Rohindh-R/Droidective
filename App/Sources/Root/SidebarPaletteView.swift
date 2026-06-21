import ADBKit
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension FeatureDef {
    /// Instant actions taking no input fire immediately (click or ⏎) and show
    /// only a toast — no detail screen. Screenshot keeps its panel (delay +
    /// preview); an unimplemented action falls back to its placeholder.
    var firesWithoutScreen: Bool {
        kind == .instantAction && id != "screenshot" && FeatureEngine.implementedIDs.contains(id)
    }
}

/// One row of the grouped sidebar's flat reorderable list: a category header or
/// a feature. Flattening into one `ForEach` lets the custom drag-and-drop
/// reorder both features (within a group) and whole groups, with a precise drop
/// guideline.
private enum SidebarRow: Identifiable {
    case header(FeatureCategory)
    case feature(FeatureDef)

    var id: String {
        switch self {
        case .header(let category): return "header:" + category.rawValue
        case .feature(let feature): return "feature:" + feature.id
        }
    }
}

/// Where the drop guideline is drawn during a sidebar drag.
private enum DropSlot: Equatable {
    case beforeRow(String)    // above a feature row (its id)
    case afterRow(String)     // below a group's last feature row (its id) — end of group
    case topOfGroup(String)   // below a header (category raw) — group's first slot
    case beforeGroup(String)  // above a header (category raw) — group boundary
}

/// Drop target for one flattened sidebar row. Resolves where the guideline goes
/// for the current drag: a feature drag only targets feature slots in its own
/// group; a group drag only targets group boundaries (so its guideline never
/// lands between a group's feature rows).
private struct SidebarDrop: DropDelegate {
    let target: SidebarRow
    let dragID: String?
    /// The target is the last feature row in its group — its lower half maps to
    /// `.afterRow` (end of group), the one slot a top guideline can't reach.
    let isLastFeature: Bool
    /// Measured height of the target row (0 if not yet measured).
    let rowHeight: CGFloat
    let setSlot: (DropSlot?) -> Void
    let perform: (DropSlot, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { slot(info) != nil }
    func dropEntered(info: DropInfo) { setSlot(slot(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let here = slot(info)
        setSlot(here)
        return here == nil ? nil : DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { setSlot(nil) }
    func performDrop(info: DropInfo) -> Bool {
        guard let dragID, let slot = slot(info) else { return false }
        perform(slot, dragID)
        return true
    }

    private func slot(_ info: DropInfo) -> DropSlot? {
        guard let dragID else { return nil }
        let draggingGroup = dragID.hasPrefix("group:")
        switch target {
        case .header(let category):
            if draggingGroup { return .beforeGroup(category.rawValue) }
            return featureCategory(dragID) == category ? .topOfGroup(category.rawValue) : nil
        case .feature(let feature):
            if draggingGroup { return .beforeGroup(feature.category.rawValue) }
            guard featureCategory(dragID) == feature.category else { return nil }
            if isLastFeature, rowHeight > 0, info.location.y > rowHeight / 2 {
                return .afterRow(feature.id)
            }
            return .beforeRow(feature.id)
        }
    }

    private func featureCategory(_ dragID: String) -> FeatureCategory? {
        guard dragID.hasPrefix("feature:") else { return nil }
        return FeatureRegistry.byID[String(dragID.dropFirst("feature:".count))]?.category
    }
}

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
    /// Active sidebar drag: "feature:<id>" or "group:<rawValue>", nil when idle.
    @State private var dragID: String?
    /// Where the insertion guideline shows during a drag.
    @State private var dropSlot: DropSlot?
    /// Measured feature-row heights (id → height) for top/bottom drop halves.
    @State private var rowHeights: [String: CGFloat] = [:]
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
                    } else {
                        Button {
                            state.searchText = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.textMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .onSubmit { runTopMatch() }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }

            ScrollViewReader { proxy in
            List {
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
                    // Custom drag-and-drop (not List.onMove, which raced the row
                    // tap gestures and dropped intermittently). Drag a feature to
                    // reorder within its group; drag a header to move the whole
                    // group. The guideline is drawn between rows for a feature
                    // drag and only at group boundaries for a group drag.
                    Section {
                        ForEach(groupedRows) { row in
                            groupedRow(row, shortcutRank: shortcutRank)
                        }
                    }
                } else {
                    // Ungrouped: the user's custom order, drag to reorder.
                    Section {
                        let ordered = state.orderedEnabledFeatures
                        ForEach(ordered) { feature in
                            FeatureRowView(feature: feature, shortcutIndex: shortcutRank[feature.id])
                        }
                        .onMove { source, destination in
                            state.reorderFeatures(ordered, from: source, to: destination)
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
            .onChange(of: state.selectedFeatureID) { _, id in
                proxy.scrollTo(id, anchor: .center)
            }
            }

            Divider()
            bottomBar
        }
        .background(.bgSurface)
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
            .foregroundStyle(state.selectedFeatureID == "home" ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
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
            .foregroundStyle(state.selectedFeatureID == "catalog" ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))

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
            .foregroundStyle(state.selectedFeatureID == "about" ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
            .help("About & Feedback — version, report an issue, star on GitHub")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.textMuted)
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

    /// The grouped sidebar flattened to a single list: each non-empty category
    /// contributes a header row then its (shown) feature rows.
    private var groupedRows: [SidebarRow] {
        state.sidebarCategories.flatMap { category -> [SidebarRow] in
            [.header(category)] + state.shownFeatures(in: category).map(SidebarRow.feature)
        }
    }

    /// Renders one flattened sidebar row. The drag starts from the row's grip
    /// handle (not the whole row), so it never competes with the tap-to-open /
    /// click-to-collapse gesture; the whole row is the drop target.
    @ViewBuilder
    private func groupedRow(_ row: SidebarRow, shortcutRank: [String: Int]) -> some View {
        switch row {
        case .header(let category):
            GroupHeaderView(
                category: category, compact: true, showsDragHandle: true,
                collapsed: state.isCategoryCollapsed(category),
                onToggleCollapse: { state.toggleCategoryCollapsed(category) },
                dragProvider: { startDrag("group:" + category.rawValue) }
            )
            .overlay(alignment: .top) { guideline(dropSlot == .beforeGroup(category.rawValue)).offset(y: -6) }
            .overlay(alignment: .bottom) { guideline(dropSlot == .topOfGroup(category.rawValue)).offset(y: 6) }
            .onDrop(of: [.text], delegate: dropDelegate(for: row))
        case .feature(let feature):
            FeatureRowView(
                feature: feature, shortcutIndex: shortcutRank[feature.id],
                dragProvider: { startDrag("feature:" + feature.id) }
            )
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                        rowHeights[feature.id] = height
                    }
                }
            )
            .overlay(alignment: .top) { guideline(dropSlot == .beforeRow(feature.id)).offset(y: -6) }
            .overlay(alignment: .bottom) { guideline(dropSlot == .afterRow(feature.id)).offset(y: 6) }
            .onDrop(of: [.text], delegate: dropDelegate(for: row))
        }
    }

    /// The accent insertion indicator shown at a drop slot — a thin line capped
    /// with a tick at each end (|–––|).
    @ViewBuilder
    private func guideline(_ show: Bool) -> some View {
        if show {
            HStack(spacing: 0) {
                guidelineCap
                Rectangle().fill(Color.brandAccent).frame(height: 2)
                guidelineCap
            }
            .frame(height: 6)
            .padding(.horizontal, 6)
        }
    }

    private var guidelineCap: some View {
        RoundedRectangle(cornerRadius: 1).fill(Color.brandAccent).frame(width: 3, height: 6)
    }

    private func startDrag(_ payload: String) -> NSItemProvider {
        dragID = payload
        dropSlot = nil
        return NSItemProvider(object: payload as NSString)
    }

    private func dropDelegate(for row: SidebarRow) -> SidebarDrop {
        SidebarDrop(
            target: row,
            dragID: dragID,
            isLastFeature: isLastFeature(row),
            rowHeight: rowHeight(for: row),
            setSlot: { dropSlot = $0 },
            perform: { slot, dragged in performSidebarDrop(slot, dragged) }
        )
    }

    /// Whether `row` is the last shown feature in its category (the only row
    /// whose lower half offers an end-of-group drop).
    private func isLastFeature(_ row: SidebarRow) -> Bool {
        guard case let .feature(feature) = row else { return false }
        return state.shownFeatures(in: feature.category).last?.id == feature.id
    }

    private func rowHeight(for row: SidebarRow) -> CGFloat {
        guard case let .feature(feature) = row else { return 0 }
        return rowHeights[feature.id] ?? 0
    }

    /// Apply a completed sidebar drop, then clear the drag state.
    private func performSidebarDrop(_ slot: DropSlot, _ dragged: String) {
        defer { dragID = nil; dropSlot = nil }
        if dragged.hasPrefix("group:") {
            let raw = String(dragged.dropFirst("group:".count))
            if case let .beforeGroup(targetRaw) = slot { state.moveGroup(raw, before: targetRaw) }
            return
        }
        let fid = String(dragged.dropFirst("feature:".count))
        guard let category = FeatureRegistry.byID[fid]?.category else { return }
        let group = state.enabledFeatures(in: category)
        let toIndex: Int
        switch slot {
        case .beforeRow(let targetID): toIndex = group.firstIndex { $0.id == targetID } ?? group.count
        case .afterRow(let targetID): toIndex = group.firstIndex { $0.id == targetID }.map { $0 + 1 } ?? group.count
        case .topOfGroup: toIndex = 0
        case .beforeGroup: return
        }
        state.moveFeature(fid, toIndex: toIndex, in: category)
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
            body = state.sidebarCategories.flatMap { state.shownFeatures(in: $0) }
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

    /// ⏎ in the search field: fire the top instant action with no screen, else
    /// open the top match's detail.
    private func runTopMatch() {
        let target = orderedMatches.first { $0.id == state.selectedFeatureID } ?? orderedMatches.first
        guard let target else { return }
        if target.firesWithoutScreen {
            Task { await state.run(feature: target, params: [:]) }
        } else {
            state.selectedFeatureID = target.id
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
    /// When set, a hover-revealed grip drags this row to reorder it (grouped
    /// sidebar only). Kept off the row body so it never competes with the tap.
    var dragProvider: (() -> NSItemProvider)?
    @State private var showingHotkey = false
    @State private var hovering = false

    private var isPinned: Bool { state.layout.favorites.contains(feature.id) }
    private var isEnabled: Bool { state.layout.effectiveEnabledIDs.contains(feature.id) }
    private var isSelected: Bool { state.selectedFeatureID == feature.id }

    /// Clicking a row selects it — except an instant action that fires without
    /// a screen, which just runs (feedback is the toast + clipboard) and leaves
    /// the current detail pane untouched.
    private func activate() {
        if feature.firesWithoutScreen {
            Task { await state.run(feature: feature, params: [:]) }
        } else {
            state.selectedFeatureID = feature.id
        }
    }

    /// Trailing edge of a row: a hover-revealed pin button, then a live switch
    /// for toggle features (flip the override without opening a screen) or the
    /// ⌘<n> jump hint.
    @ViewBuilder private var trailingControl: some View {
        HStack(spacing: 4) {
            if let dragProvider {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.textMuted)
                    .opacity(hovering ? 1 : 0)
                    .onDrag(dragProvider)
                    .help("Drag to reorder")
            }
            if !dimmed {
                pinButton
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            if feature.kind == .toggleAction {
                OverrideToggleControl(feature: feature) { _ in EmptyView() }
                    .labelsHidden()
                    .controlSize(.mini)
            } else if let shortcutIndex {
                KeyHint("⌘\(shortcutIndex + 1)")
            }
        }
        .padding(.leading, 6)
    }

    /// Pin/unpin this feature to the top of the sidebar. Hidden until the row
    /// is hovered (the pinned rows live in their own section, so the filled pin
    /// is only needed as the unpin affordance on hover).
    private var pinButton: some View {
        Button {
            state.toggleFavorite(feature.id)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .foregroundStyle(isPinned ? AnyShapeStyle(.orange) : AnyShapeStyle(.textMuted))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin from top" : "Pin to top")
    }

    /// Icon tint: brand green for the active row, quiet gray otherwise. Static
    /// asset colors (not `.tint`), so they keep their color when the window is
    /// inactive.
    private var iconStyle: AnyShapeStyle {
        (isSelected && !dimmed) ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted)
    }

    /// Selection highlight drawn by us, not the system list. The native sidebar
    /// selection fills with the accent (graying when the window is inactive) and
    /// would clash with the green label; a subtle static brand pill keeps the
    /// selection legible and stable on focus change.
    @ViewBuilder private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.brandAccent.opacity(0.14))
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(feature.title)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMain))
                        .lineLimit(1)
                    if let subtitle = feature.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.textMuted)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: feature.icon)
                    .foregroundStyle(iconStyle)
            }
            // Tap target is the label/icon only, so a toggle row's switch keeps
            // its own taps and flips without navigating.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { activate() }

            trailingControl
        }
        .opacity(dimmed ? 0.75 : 1)
        .listRowBackground(rowBackground)
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .contextMenu {
            // Hub members live in their hub, so pinning/enabling them as
            // standalone rows doesn't apply — only the hotkey does.
            if !feature.isAbsorbedByHub {
                Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
                    state.toggleFavorite(feature.id)
                }
                if feature.kind != .system {
                    Button(isEnabled ? "Disable" : "Enable", systemImage: isEnabled ? "eye.slash" : "eye") {
                        state.setFeatureEnabled(feature.id, enabled: !isEnabled)
                    }
                }
                Divider()
            }
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
                .foregroundStyle(.textMuted)
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
                    .foregroundStyle(.textMuted)
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
