import ADBKit
import AppKit
import SwiftUI

/// Spotlight-style floating search palette (⌘K): type, arrow through
/// matches, ⏎ jumps to the feature in the main window. Esc closes.
struct PaletteWindowView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [FeatureDef] {
        let enabled = state.layout.effectiveEnabledIDs
        let all = FeatureRegistry.all.filter { $0.matches(query) }
        // Enabled features first, then disabled matches.
        return all.filter { enabled.contains($0.id) } + all.filter { !enabled.contains($0.id) }
    }

    private var visibleMatches: [FeatureDef] {
        Array(matches.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search features…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { open(at: highlighted) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
            }
            .padding(14)

            if !visibleMatches.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(visibleMatches.enumerated()), id: \.element.id) { index, feature in
                        paletteRow(feature, isHighlighted: index == highlighted)
                            .onTapGesture { open(at: index) }
                    }
                }
                .padding(6)
            } else if !query.isEmpty {
                Divider()
                Text("No matching features")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .onExitCommand { close() }
        .onAppear {
            query = ""
            highlighted = 0
            configureWindow()
            // Focus must land after the window becomes key — setting it
            // synchronously in onAppear loses the race.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                fieldFocused = true
            }
        }
        .onChange(of: query) { highlighted = 0 }
        // Spotlight behavior: clicking anywhere else dismisses the palette.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let window = note.object as? NSWindow,
               window.identifier?.rawValue.contains("palette") == true {
                close()
            }
        }
    }

    private func paletteRow(_ feature: FeatureDef, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feature.icon)
                .frame(width: 22)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
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
            if !state.layout.effectiveEnabledIDs.contains(feature.id) {
                Text("disabled")
                    .font(.caption2)
                    .foregroundStyle(isHighlighted ? .white.opacity(0.75) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
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
        state.selectedFeatureID = feature.id
    }

    private func close() {
        dismissWindow(id: "palette")
    }

    /// Float above everything, minimal chrome, centered — Spotlight-like.
    /// The window keeps its normal opaque backing: a clear background plus a
    /// clipped view leaves transparent corners and a see-through title strip.
    private func configureWindow() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("palette") == true }) else {
            return
        }
        window.level = .floating
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
