import ADBKit
import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth = 300.0
    @AppStorage("hasSeenTour") private var hasSeenTour = false
    @AppStorage("hasChosenRole") private var hasChosenRole = false
    @AppStorage("telemetryConsentAsked") private var consentAsked = false
    @AppStorage("launchCount") private var launchCount = 0
    @AppStorage("starPromptShown") private var starPromptShown = false
    @State private var presentConsent = false
    @State private var presentStar = false
    /// True only while the *first-run* role picker is up, so its dismissal
    /// chains into the welcome tour. Changing role later (pill / Settings)
    /// leaves this false, so the tour never reappears.
    @State private var pickerIsFirstRun = false
    @Environment(\.colorScheme) private var colorScheme

    /// Temporary toggle: flip to `true` to surface the privacy disclosure on the
    /// first launch (after the welcome flow) instead of deferring it. Left
    /// `false` for now to keep current behavior. Telemetry stays anonymous and
    /// on by default either way (opt-out in Settings → Privacy). Remove this
    /// (and the deferral below) when switching to ask-on-first-launch for good.
    private let askConsentOnFirstLaunch = false

    /// Launches to allow before the first-run privacy disclosure appears, when
    /// `askConsentOnFirstLaunch` is false.
    private let consentPromptAfterLaunches = 5

    /// Launches before the one-time GitHub-star nudge (shown after consent).
    private let starPromptAfterLaunches = 10

    private var shouldPromptConsent: Bool {
        guard !consentAsked else { return false }
        return askConsentOnFirstLaunch || launchCount >= consentPromptAfterLaunches
    }

    private var shouldPromptStar: Bool {
        !starPromptShown && launchCount >= starPromptAfterLaunches
    }

    var body: some View {
        @Bindable var state = state
        // Read pendingExit here so body re-renders when a navigation is deferred
        // (the exitGuard alone is often unchanged), driving the leave dialog.
        let showExitDialog = state.pendingExit.map { !$0.saving } ?? false
        return zoomedContent
            .background(WindowAccessor { window in
                // Fill the screen's usable area on launch — a regular maximized
                // window, not a native full-screen Space.
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true)
                }
            })
            .overlay {
                // Full-window takeover (macOS has no fullScreenCover), shown
                // before the tour for brand-new users and from "Change role".
                if state.presentRolePicker {
                    RolePickerView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state.presentRolePicker)
            .sheet(isPresented: $state.presentTour) {
                TourView()
            }
            .background {
                // Separate host view: two .sheet modifiers on one view can drop
                // one, and the deferred privacy consent must still reliably show.
                Color.clear.sheet(isPresented: $presentConsent) {
                    TelemetryConsentView()
                }
            }
            .background {
                // Its own host view for the same reason as the consent sheet.
                Color.clear.sheet(isPresented: $presentStar) {
                    StarPromptView(onStar: { state.openRepository() })
                }
            }
            .onAppear {
                state.openMainWindow = { openWindow(id: "main") }
                state.openPalette = { PaletteController.shared.show(appState: state) }
                (NSApp.delegate as? AppDelegate)?.appState = state
                InstallInbox.shared.onReceive = { urls in state.openAPKs(urls) }
                migrateDefaultsIfNeeded()
                applyStoredTheme()
                updateDockIcon()
                HotkeyManager.install(state: state)
                if !hasChosenRole && !hasSeenTour {
                    // Brand-new user: pick a role first, then run the tour.
                    pickerIsFirstRun = true
                    state.presentRolePicker = true
                } else if !hasSeenTour {
                    state.presentTour = true
                } else if shouldPromptConsent {
                    presentConsent = true
                } else if shouldPromptStar {
                    presentStar = true
                }
            }
            .onChange(of: state.presentRolePicker) { _, showing in
                // Only the first-run picker chains into the tour; changing role
                // later (pill / Settings) must not reopen it.
                if !showing && pickerIsFirstRun {
                    pickerIsFirstRun = false
                    if !hasSeenTour { state.presentTour = true }
                }
            }
            .onChange(of: state.presentTour) { _, showing in
                if !showing && shouldPromptConsent { presentConsent = true }
            }
            .onChange(of: colorScheme) { _, _ in updateDockIcon() }
            .confirmationDialog(
                state.exitGuard?.title ?? "",
                isPresented: Binding(
                    get: { showExitDialog },
                    set: { shown in
                        if !shown, state.pendingExit?.saving == false { state.cancelExit() }
                    }
                ),
                titleVisibility: .visible,
                presenting: state.exitGuard
            ) { info in
                exitDialogButtons(for: info)
            } message: { info in
                Text(info.message)
            }
    }

    @ViewBuilder
    private func exitDialogButtons(for info: AppState.ExitGuard) -> some View {
        switch info.style {
        case .recording:
            Button("Stop & Save") { state.beginExitSave() }
            Button("Discard", role: .destructive) { state.discardAndExit() }
            Button("Keep Recording", role: .cancel) { state.cancelExit() }
        case .edits:
            Button("Discard", role: .destructive) { state.discardAndExit() }
            Button("Keep Editing", role: .cancel) { state.cancelExit() }
        }
    }

    /// macOS has no native light/dark app icon, so swap the Dock icon at
    /// runtime to match the active theme.
    private func updateDockIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = NSImage(named: dark ? "AppLogoDark" : "AppLogoLight")
    }

    /// One-time switch to the v2 defaults — dark appearance and how-it-works
    /// notes hidden — for users who installed before they changed. Runs once;
    /// any later manual change in Settings sticks.
    private func migrateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateDefaultsV2") else { return }
        defaults.set("dark", forKey: "theme")
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
                    .frame(width: min(max(sidebarWidth, 300), 460))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ResizeHandle(value: $sidebarWidth, range: 300...460)
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

/// Reads the hosting `NSWindow` once it attaches, so the main window can be
/// sized to fill the screen on launch. `viewDidMoveToWindow` runs on the main
/// actor with the window in place — no async hop, so it stays Swift-6 clean.
private final class WindowReaderView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    private var resolved = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !resolved, let window else { return }
        resolved = true
        onWindow?(window)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindow = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}
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
