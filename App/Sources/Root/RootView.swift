import ADBKit
import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth = 300.0
    /// Left-pane fraction (0…1) of the editor split; the layout clamps it so
    /// neither pane collapses.
    @AppStorage("tabSplitFraction") private var splitFraction = 0.5
    /// True while a dragged tab hovers the split-create zone of the sole pane.
    @State private var splitZoneTargeted = false
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
        LaunchPrompt.consentDue(
            consentAsked: consentAsked, launchCount: launchCount,
            askOnFirstLaunch: askConsentOnFirstLaunch, afterLaunches: consentPromptAfterLaunches)
    }

    private var shouldPromptStar: Bool {
        LaunchPrompt.starDue(
            starPromptShown: starPromptShown, launchCount: launchCount, afterLaunches: starPromptAfterLaunches)
    }

    var body: some View {
        @Bindable var state = state
        // Read pendingExit here so body re-renders when a navigation is deferred
        // (the exitGuard alone is often unchanged), driving the leave dialog.
        let showExitDialog = state.pendingExit.map { !$0.saving } ?? false
        return zoomedContent
            .background(WindowAccessor { window in
                // Tag the main window so the ⌘W monitor can tell it apart from
                // Settings / the palette panel.
                window.identifier = NSUserInterfaceItemIdentifier(RootView.mainWindowID)
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
            .onAppear { performLaunchSetup() }
            .onChange(of: state.presentRolePicker) { _, showing in rolePickerVisibilityChanged(showing) }
            .onChange(of: state.presentTour) { _, showing in
                if !showing && shouldPromptConsent { presentConsent = true }
            }
            .onChange(of: colorScheme) { _, _ in updateDockIcon() }
            .confirmationDialog(
                state.pendingGuard?.title ?? "",
                isPresented: Binding(
                    get: { showExitDialog },
                    set: { shown in
                        if !shown, state.pendingExit?.saving == false { state.cancelExit() }
                    }
                ),
                titleVisibility: .visible,
                presenting: state.pendingGuard
            ) { info in
                exitDialogButtons(for: info)
            } message: { info in
                Text(info.message)
            }
    }

    /// Runs once when the root view appears: wires AppState callbacks, applies
    /// stored prefs/theme/hotkeys, and shows the first due launch prompt. Kept
    /// out of `body` so the view-builder expression stays cheap to type-check.
    private func performLaunchSetup() {
        state.openMainWindow = { openWindow(id: "main") }
        state.openPalette = { PaletteController.shared.show(appState: state) }
        (NSApp.delegate as? AppDelegate)?.appState = state
        InstallInbox.shared.onReceive = { urls in state.openAPKs(urls) }
        migrateDefaultsIfNeeded()
        applyStoredTheme()
        updateDockIcon()
        HotkeyManager.install(state: state)
        installCloseTabMonitor()
        switch LaunchPrompt.next(
            hasChosenRole: hasChosenRole, hasSeenTour: hasSeenTour,
            consentAsked: consentAsked, starPromptShown: starPromptShown,
            launchCount: launchCount, askConsentOnFirstLaunch: askConsentOnFirstLaunch,
            consentAfterLaunches: consentPromptAfterLaunches, starAfterLaunches: starPromptAfterLaunches
        ) {
        case .rolePicker:
            // Brand-new user: pick a role first, then run the tour.
            pickerIsFirstRun = true
            state.presentRolePicker = true
        case .tour:
            state.presentTour = true
        case .consent:
            presentConsent = true
        case .star:
            presentStar = true
        case nil:
            break
        }
    }

    /// Identifier stamped on the main window so `installCloseTabMonitor` can
    /// scope ⌘W to it and leave Settings / the palette panel alone.
    fileprivate static let mainWindowID = "droidective-main"
    private static var closeTabMonitorInstalled = false

    /// ⌘W closes the active tab, not the window. A local key-down monitor
    /// intercepts ⌘W for the main window before AppKit's default Close-Window
    /// runs (local monitors see the event first and can swallow it); the red
    /// traffic-light button still closes the whole window. Installed once.
    private func installCloseTabMonitor() {
        guard !RootView.closeTabMonitorInstalled else { return }
        RootView.closeTabMonitorInstalled = true
        let state = self.state
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "w",
                  NSApp.keyWindow?.identifier?.rawValue == RootView.mainWindowID
            else { return event }
            state.closeActiveTab()
            return nil
        }
    }

    /// Only the first-run role picker chains into the tour; changing role later
    /// (pill / Settings) must not reopen it.
    private func rolePickerVisibilityChanged(_ showing: Bool) {
        if !showing && pickerIsFirstRun {
            pickerIsFirstRun = false
            if !hasSeenTour { state.presentTour = true }
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
                // Device bar on top (shared across panes); each pane's own tab
                // strip sits below it, inside the pane — VS Code-style.
                if state.activeTabID != "catalog" {
                    DeviceBarView()
                    if let operation = state.runningOperation {
                        OperationProgressStrip(operation: operation)
                    }
                }
                HStack(spacing: 0) {
                    panesArea
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

    /// The editor area: one pane, or two side by side split by a draggable seam.
    private var panesArea: some View {
        GeometryReader { geo in
            let leftW = splitLeftWidth(geo.size.width)
            HStack(spacing: 0) {
                pane(0).frame(width: state.isSplit ? leftW : geo.size.width)
                if state.isSplit {
                    SplitDivider(fraction: $splitFraction, totalWidth: geo.size.width)
                        .frame(width: 8)
                    pane(1).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(activeTitle)
        }
    }

    /// One editor pane: its own tab strip above its mounted tabs. Accepts a
    /// dragged tab dropped onto it (moving it into this pane's group), and — when
    /// there's only one pane — offers a trailing zone that splits on drop.
    private func pane(_ index: Int) -> some View {
        VStack(spacing: 0) {
            TabStripView(group: index)
            TabHostView(group: index)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.text], delegate: TabPaneDrop(
            draggingID: state.draggingTabID,
            onDrop: { id in state.dropTab(id, intoGroup: index, before: nil); state.draggingTabID = nil }
        ))
        .overlay(alignment: .trailing) {
            if !state.isSplit, state.draggingTabID != nil { splitCreateZone }
        }
    }

    /// Right-half drop zone shown on the sole pane while dragging a tab — drop
    /// here to open it in a new split pane. Fills the half where the new pane
    /// will land so the target is obvious.
    private var splitCreateZone: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.brandAccent.opacity(splitZoneTargeted ? 0.28 : 0.14))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.brandAccent).frame(width: 2) // the seam it'll create
                }
                .overlay {
                    Label("Drop to split", systemImage: "rectangle.split.2x1")
                        .font(.headline)
                        .foregroundStyle(.brandAccent)
                }
                .frame(width: geo.size.width / 2, height: geo.size.height)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onDrop(of: [.text], delegate: TabPaneDrop(
                    draggingID: state.draggingTabID,
                    onDrop: { id in state.splitTab(id); state.draggingTabID = nil },
                    onTargetedChange: { splitZoneTargeted = $0 }
                ))
        }
    }

    private func splitLeftWidth(_ totalW: CGFloat) -> CGFloat {
        let dividerW: CGFloat = 8
        let minPane: CGFloat = 320
        let available = totalW - dividerW
        return min(max(available * splitFraction, minPane), max(minPane, available - minPane))
    }

    private var activeTitle: String {
        guard let id = state.activeTabID else { return "" }
        if id == "catalog" { return "Feature Catalog" }
        return FeatureRegistry.byID[id]?.title ?? ""
    }
}

/// Hosts one editor group's tabs. All the group's tabs stay mounted in a ZStack
/// — so an active recording or a live log stream keeps running when you switch
/// to another tab in the same pane, and a tab keeps its view state when you come
/// back — with only the group's active tab visible and interactive. Each tab is
/// handed its feature id and whether it's on screen via the environment, which
/// device-heavy live views (network/CPU polling, the mirror) use to pause while
/// hidden. (Moving a tab to the other pane recreates it, so a recording stops if
/// dragged across panes — switching within a pane is the keep-alive path.)
struct TabHostView: View {
    @Environment(AppState.self) private var state
    let group: Int

    var body: some View {
        let ids = state.openTabIDs(inGroup: group)
        let active = state.activeTab(inGroup: group)
        ZStack {
            ForEach(ids, id: \.self) { id in
                FeatureDetailView(featureID: id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.tabFeatureID, id)
                    .environment(\.tabIsActive, id == active)
                    .opacity(id == active ? 1 : 0)
                    .allowsHitTesting(id == active)
                    .accessibilityHidden(id != active)
                    .zIndex(id == active ? 1 : 0)
            }
        }
    }
}

/// Accepts a tab dragged from a strip onto a pane (or the split-create zone).
/// The dragged id lives in `AppState.draggingTabID`; the dropped `.text` item
/// only triggers the drop. `onTargetedChange` drives an optional hover highlight.
struct TabPaneDrop: DropDelegate {
    let draggingID: String?
    let onDrop: (String) -> Void
    var onTargetedChange: ((Bool) -> Void)?

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }
    func dropEntered(info: DropInfo) { onTargetedChange?(true) }
    func dropExited(info: DropInfo) { onTargetedChange?(false) }
    func performDrop(info: DropInfo) -> Bool {
        onTargetedChange?(false)
        guard let id = draggingID else { return false }
        onDrop(id)
        return true
    }
}

/// The draggable seam between the two split panes. Stores a fraction (0…1) of
/// the total width so the split survives window resizes; the host clamps it so
/// neither pane collapses.
private struct SplitDivider: View {
    @Binding var fraction: Double
    let totalWidth: CGFloat
    @State private var startFraction: Double?

    var body: some View {
        Color.clear
            .overlay { Rectangle().fill(Color.borderSubtle).frame(width: 1) }
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.set() : NSCursor.arrow.set() }
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        let base = startFraction ?? fraction
                        if startFraction == nil { startFraction = fraction }
                        let delta = totalWidth > 0 ? gesture.translation.width / totalWidth : 0
                        fraction = min(0.8, max(0.2, base + delta))
                    }
                    .onEnded { _ in startFraction = nil }
            )
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
