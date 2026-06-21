import ADBKit
import SwiftUI

/// Feature catalog: every feature is on by default; turn off the ones you don't
/// want here (a disabled feature leaves the sidebar but stays searchable and
/// hotkey-able). Whole groups toggle from a right-click on the header. Features
/// list in the sidebar's order; reordering and pinning live on the sidebar rows.
struct CatalogView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            ForEach(state.orderedCategories, id: \.self) { category in
                let features = state.catalogFeatures(in: category)
                if !features.isEmpty {
                    Section {
                        ForEach(features) { feature in
                            row(feature)
                        }
                    } header: {
                        GroupHeaderView(category: category)
                    }
                }
            }
        }
    }

    private func row(_ feature: FeatureDef) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feature.icon)
                .frame(width: 20)
                .foregroundStyle(.textMuted)
            VStack(alignment: .leading) {
                Text(feature.title)
                if let subtitle = feature.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.textMuted)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.layout.effectiveEnabledIDs.contains(feature.id) },
                set: { state.setFeatureEnabled(feature.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(feature.kind == .system)
        }
        .padding(.vertical, 2)
    }
}

/// A category section header shared by the catalog and the sidebar. In the
/// sidebar a single click collapses/expands the group (disclosure chevron), the
/// whole row is draggable to reorder groups (the list's `.onMove`), and a grip
/// hints at that. Right-click enables or disables every feature in the group.
/// The catalog header is static (no chevron, grip, or collapse).
struct GroupHeaderView: View {
    @Environment(AppState.self) private var state
    let category: FeatureCategory
    /// Compact styling for the dense sidebar header vs. the roomy catalog one.
    var compact = false
    /// Show the grip glyph that hints the row can be dragged (sidebar only).
    var showsDragHandle = false
    var collapsed = false
    /// When set, a single click toggles collapse and a disclosure chevron shows.
    var onToggleCollapse: (() -> Void)?
    /// When set, dragging the grip reorders this group (sidebar only). Kept on
    /// the grip, not the whole header, so it never competes with the tap.
    var dragProvider: (() -> NSItemProvider)?

    @State private var hovering = false

    var body: some View {
        if state.canToggleGroup(category) {
            header.contextMenu {
                let enabled = state.isGroupEnabled(category)
                Button(enabled ? "Disable all" : "Enable all", systemImage: enabled ? "eye.slash" : "eye") {
                    state.setGroupEnabled(category, enabled: !enabled)
                }
            }
        } else {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if onToggleCollapse != nil {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.textMuted)
                    .frame(width: 9)
            }
            Text(category.label)
            Spacer(minLength: 0)
            if showsDragHandle {
                let grip = Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.textMuted)
                    .font(.body)
                Group {
                    if let dragProvider {
                        grip.onDrag(dragProvider).help("Drag to reorder this group")
                    } else {
                        grip
                    }
                }
                // Only hint the grip while hovering the header, so it isn't
                // always-on clutter next to every group title.
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .font(compact ? .caption : nil)
        .foregroundStyle(compact ? AnyShapeStyle(.textMuted) : AnyShapeStyle(.primary))
        .textCase(compact ? .uppercase : nil)
        // Breathing room so the drop guideline (drawn at the row's top/bottom
        // edge during a drag) sits clear of the label instead of touching it.
        .padding(.vertical, compact ? 6 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onToggleCollapse?() }
        .help(onToggleCollapse != nil
            ? "Click to collapse · drag to reorder · right-click to enable/disable the group"
            : "Right-click to enable or disable the whole group")
    }
}
