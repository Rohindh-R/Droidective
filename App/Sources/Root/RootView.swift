import ADBKit
import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth = 280.0
    @AppStorage("hasSeenTour") private var hasSeenTour = false
    @AppStorage("telemetryConsentAsked") private var consentAsked = false
    @State private var presentConsent = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var state = state
        zoomedContent
            .sheet(isPresented: $state.presentTour) {
                TourView()
            }
            .background {
                // Separate host view: two .sheet modifiers on one view can drop
                // one, and first-run privacy consent must always show.
                Color.clear.sheet(isPresented: $presentConsent) {
                    TelemetryConsentView()
                }
            }
            .onAppear {
                state.openMainWindow = { openWindow(id: "main") }
                state.openPalette = { openWindow(id: "palette") }
                migrateDefaultsIfNeeded()
                applyStoredTheme()
                updateDockIcon()
                HotkeyManager.install(state: state)
                if !hasSeenTour {
                    state.presentTour = true
                } else if !consentAsked {
                    presentConsent = true
                }
            }
            .onChange(of: state.presentTour) { _, showing in
                if !showing && !consentAsked { presentConsent = true }
            }
            .onChange(of: colorScheme) { _, _ in updateDockIcon() }
    }

    /// macOS has no native light/dark app icon, so swap the Dock icon at
    /// runtime to match the active theme.
    private func updateDockIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = NSImage(named: dark ? "AppLogoDark" : "AppLogoLight")
    }

    /// One-time switch to the v2 defaults — Auto appearance and how-it-works
    /// notes hidden — for users who installed before they changed. Runs once;
    /// any later manual change in Settings sticks.
    private func migrateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateDefaultsV2") else { return }
        defaults.set("auto", forKey: "theme")
        defaults.set(false, forKey: "showFeatureNotes")
        defaults.set(true, forKey: "didMigrateDefaultsV2")
    }

    /// macOS ignores SwiftUI dynamic type, so ⌘=/⌘- zoom is done by scaling the
    /// content: it's laid out at size/scale, then scaled up to fill the window,
    /// which enlarges every font and reflows the layout. The GeometryReader and
    /// scaleEffect wrap `split` unconditionally — at 1.0× it's an identity
    /// transform (no coordinate offset, so `.help`/hover/chart selection keep
    /// working) — so `split` holds one stable view identity across zoom steps.
    /// Branching on the scale (plain `split` at 1.0×, wrapped otherwise) moved
    /// `split` between two conditional branches, which rebuilt the subtree and
    /// wiped descendants' @State (e.g. a captured screenshot) on every zoom
    /// across 1.0×.
    private var zoomedContent: some View {
        GeometryReader { geo in
            split
                .frame(
                    width: geo.size.width / state.fontScale,
                    height: geo.size.height / state.fontScale
                )
                .scaleEffect(state.fontScale, anchor: .topLeading)
        }
    }

    /// Plain HStack split (not NavigationSplitView) for a flat, flush,
    /// full-height VS Code-style sidebar with a single continuous divider.
    private var split: some View {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                SidebarPaletteView()
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ResizeHandle(value: $sidebarWidth, range: 200...460)
            }
            VStack(spacing: 0) {
                // The catalog has no device context, so its device bar is hidden.
                if state.selectedFeatureID != "catalog" {
                    DeviceBarView()
                    if let operation = state.runningOperation {
                        OperationProgressStrip(operation: operation)
                    }
                }
                HStack(spacing: 0) {
                    FeatureDetailView(featureID: state.selectedFeatureID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) { ToastOverlay() }
                    if state.showNotifications {
                        Divider()
                        NotificationPanelView()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.bgRoot)
            .animation(.spring(duration: 0.28), value: state.showNotifications)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.textMain)
    }
}

/// A draggable divider that resizes an adjacent pane. `value` is the pane's
/// size (bound to a persisted @AppStorage). `inverted` is for panes that grow
/// when dragging toward the start (e.g. a bottom bar dragged upward).
struct ResizeHandle: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var axis: Axis = .horizontal
    var inverted = false
    @State private var startValue: Double?

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(
                        width: axis == .horizontal ? 8 : nil,
                        height: axis == .vertical ? 8 : nil
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let base = startValue ?? value
                                if startValue == nil { startValue = value }
                                let delta = axis == .horizontal ? gesture.translation.width : gesture.translation.height
                                let next = base + (inverted ? -delta : delta)
                                value = min(max(next, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startValue = nil }
                    )
            }
    }
}

/// Progress strip pinned under the device bar: a real percentage bar when
/// the transfer size is known, a spinner otherwise.
struct OperationProgressStrip: View {
    let operation: AppState.OperationStatus

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = operation.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("\(Int(fraction * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.textMuted)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(operation.label)
                .font(.footnote)
                .foregroundStyle(.textMuted)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bgSurface)
        .overlay(alignment: .bottom) { Divider() }
    }
}
