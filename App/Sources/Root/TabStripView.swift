import ADBKit
import SwiftUI

/// One editor pane's tab strip. Tabs scroll sideways when they overflow (‹ ›
/// arrows appear); the active one is highlighted and kept in view. A recording
/// tab shows a pulsing red dot. A trailing + opens the search palette. Tabs drag
/// to reorder within the pane, or onto the other pane / the split zone to move.
struct TabStripView: View {
    @Environment(AppState.self) private var state
    /// Which editor group (pane) this strip drives.
    let group: Int
    /// Measured widths for overflow detection and drop-side (before/after) math.
    @State private var chipWidths: [String: CGFloat] = [:]
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    /// Index the ‹ › arrows last scrolled to — stepped on each press.
    @State private var scrollAnchor = 0

    private var tabIDs: [String] { state.openTabIDs(inGroup: group) }
    private var activeID: String? { state.activeTab(inGroup: group) }
    /// The tabs are wider than the visible strip — show the ‹ › scroll arrows.
    private var overflowing: Bool { contentWidth > viewportWidth + 1 }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if overflowing {
                    scrollArrow("chevron.left", by: -1, help: "Scroll tabs left", proxy)
                    Divider().frame(height: 20)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabIDs, id: \.self) { id in
                            chip(id)
                        }
                        newTabButton
                    }
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                    .background(widthReader { contentWidth = $0 })
                }
                .frame(maxWidth: .infinity)
                .background(widthReader { viewportWidth = $0 })
                .onChange(of: activeID) { _, id in
                    // Bring this pane's active tab into view when it changes off-screen.
                    guard let id else { return }
                    if let index = tabIDs.firstIndex(of: id) { scrollAnchor = index }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }

                if overflowing {
                    Divider().frame(height: 20)
                    scrollArrow("chevron.right", by: 1, help: "Scroll tabs right", proxy)
                }
            }
        }
        .frame(height: 36)
        .background(.bgSurface)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Nudge the horizontal scroll by a few tabs (single click) — reveals hidden
    /// tabs without changing which tab is focused.
    private func scrollArrow(_ icon: String, by direction: Int, help: String, _ proxy: ScrollViewProxy) -> some View {
        Button {
            let ids = tabIDs
            guard !ids.isEmpty else { return }
            scrollAnchor = min(max(scrollAnchor + direction * 3, 0), ids.count - 1)
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(ids[scrollAnchor], anchor: .leading) }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chip(_ id: String) -> some View {
        TabChip(
            title: Self.title(id),
            icon: Self.icon(id),
            isActive: id == activeID,
            isRecording: state.tabIsRecording(id),
            onSelect: { state.requestFeature(id) },
            onClose: { state.closeTab(id) }
        )
        .id(id)
        .background(widthReader { chipWidths[id] = $0 })
        .onDrag {
            state.draggingTabID = id
            return NSItemProvider(object: id as NSString)
        }
        .onDrop(of: [.text], delegate: TabReorderDrop(
            targetID: id,
            width: chipWidths[id] ?? 0,
            order: tabIDs,
            draggingID: state.draggingTabID,
            move: { dragged, before in state.dropTab(dragged, intoGroup: group, before: before) },
            end: { state.draggingTabID = nil }
        ))
        .contextMenu { tabMenu(for: id) }
    }

    /// Reports a view's width via a background GeometryReader (the pattern the
    /// sidebar uses to measure rows).
    private func widthReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width, initial: true) { _, width in update(width) }
        }
    }

    /// Right-click menu for a tab: move it across the split, or close it.
    @ViewBuilder
    private func tabMenu(for id: String) -> some View {
        if state.isSplit {
            Button("Move to Other Pane") { state.moveTab(id, toGroup: group == 0 ? 1 : 0) }
        } else {
            Button("Split: Move to New Pane") { state.splitTab(id) }
        }
        Divider()
        Button("Close Tab") { state.closeTab(id) }
    }

    private var newTabButton: some View {
        Button {
            // Focus this pane first so the chosen feature opens here, not in
            // whichever pane happened to be focused.
            state.focusGroup(group)
            state.openPalette?()
        } label: {
            Image(systemName: "plus")
                .font(.callout.weight(.medium))
                .foregroundStyle(.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New tab (⌘T)")
    }

    /// Title shown on a tab chip — the registry title, or the standalone
    /// Home / Manage Features / About screens which aren't registry features.
    static func title(_ id: String) -> String {
        switch id {
        case "home": return "Home"
        case "catalog": return "Manage Features"
        case "about": return "About"
        default: return FeatureRegistry.byID[id]?.title ?? id
        }
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "home": return "house"
        case "catalog": return "square.grid.2x2"
        case "about": return "info.circle"
        default: return FeatureRegistry.byID[id]?.icon ?? "square"
        }
    }
}

/// One tab in the strip. The close button appears on hover (or when active) but
/// its width is always reserved, so the chip doesn't jump as the pointer moves.
private struct TabChip: View {
    let title: String
    let icon: String
    let isActive: Bool
    let isRecording: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? AnyShapeStyle(.textMain) : AnyShapeStyle(.textMuted))
            closeButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .frame(maxWidth: 190)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? AnyShapeStyle(.brandAccent.opacity(0.14)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var leading: some View {
        if isRecording {
            // Pulsing red dot while the tab is recording (screen / mirror /
            // performance / network capture).
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        } else {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isActive ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
        }
    }

    @ViewBuilder private var closeButton: some View {
        if hovering || isActive {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.textMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab (⌘W)")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

/// Drop delegate for reordering tabs: dropping a dragged tab on a chip's left
/// half inserts it before that chip, on the right half after it. `move` is a
/// no-op when the ids resolve to the same slot (handled by `SidebarOrdering`).
private struct TabReorderDrop: DropDelegate {
    let targetID: String
    let width: CGFloat
    let order: [String]
    let draggingID: String?
    let move: (_ dragged: String, _ beforeTargetID: String?) -> Void
    let end: () -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { end() }
        guard let dragged = draggingID, dragged != targetID else { return false }
        let dropAfter = width > 0 && info.location.x > width / 2
        if dropAfter, let index = order.firstIndex(of: targetID) {
            // After the target = before the tab that follows it (or to the end).
            move(dragged, order.indices.contains(index + 1) ? order[index + 1] : nil)
        } else {
            move(dragged, targetID)
        }
        return true
    }
}
