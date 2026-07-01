import ADBKit
import AppKit
import Foundation
import Observation
import SwiftUI

struct Toast: Identifiable, Equatable {
    enum Level: Equatable {
        case success, info, warning, error
    }

    let id = UUID()
    let message: String
    let ok: Bool
    let level: Level
    var copyText: String?
    var revealPath: String?
    /// Whether this is kept in the notifications history. Errors and warnings
    /// always are; a success only when it produced an artifact (a reveal
    /// path) — routine confirmations like "Copied" are dropped.
    let important: Bool

    init(
        message: String,
        ok: Bool,
        level: Level? = nil,
        copyText: String? = nil,
        revealPath: String? = nil,
        important: Bool? = nil
    ) {
        self.message = message
        self.ok = ok
        let resolved = level ?? (ok ? .success : .error)
        self.level = resolved
        self.copyText = copyText
        self.revealPath = revealPath
        self.important = important
            ?? (resolved == .error || resolved == .warning || revealPath != nil)
    }
}

/// A notification kept in the history panel — the important subset of toasts.
struct AppNotification: Identifiable, Equatable {
    let id: UUID
    let message: String
    let level: Toast.Level
    var copyText: String?
    var revealPath: String?
    let date: Date
}

@MainActor
@Observable
final class AppState {
    let env: AppEnvironment

    /// APK Studio's loaded-APK session. In-memory, so it resumes across
    /// navigation within a run and is cleared when the app quits (the decompiled
    /// cache is wiped alongside it — see `AppDelegate.applicationWillTerminate`).
    let apkStudio = ApkStudioSession()

    var devices: [Device] = []
    /// Android Studio AVDs, for launching an emulator straight from the device
    /// bar. Refreshed when the connected set changes (see `refreshAvds`); ones
    /// with a `runningSerial` are already in `devices`.
    var availableAvds: [Avd] = []
    /// Switch via `requestDevice(_:)`, not direct assignment — that routes the
    /// change through the leave guard so an active recording isn't lost.
    private(set) var selectedSerial: String?
    var runOnAll = false
    var searchText = ""
    /// The sidebar/palette's keyboard-navigation highlight (↑/↓ while searching).
    /// Transient (not persisted) and separate from the active tab, so arrowing
    /// through results moves a highlight without opening a tab per keystroke —
    /// only ⏎ / click / ⌘<n> opens one.
    var searchHighlightID: String?
    /// The editor-group workspace (VS Code-style split panes): one pane = no
    /// split, two = a left/right split. Each pane owns its tabs and active tab; a
    /// feature is open in at most one pane, so dragging a tab between panes MOVES
    /// it. All the multi-pane rules (collapse, cap, uniqueness, focus, never
    /// empty) live in the pure, tested `Workspace`; mutate via the methods below
    /// so each change persists. Tabs stay mounted, so switching within a pane
    /// never destroys in-flight work — the leave guard fires on *closing* a tab
    /// (or quitting), not on switching.
    private(set) var workspace = Workspace(fallback: "home")

    /// The tab id being dragged in a strip, or nil when no drag is in flight —
    /// shared so a pane can offer a drop target for moving/splitting tabs.
    var draggingTabID: String?

    /// The focused pane's active tab: drives the device bar, sidebar highlight,
    /// and window title.
    var activeTabID: String? { workspace.activeTab }
    /// Both panes' active tabs — the sidebar highlights all of them.
    var activeTabIDs: Set<String> { workspace.activeTabs }
    /// True when the workspace is split into two panes.
    var isSplit: Bool { workspace.isSplit }
    /// The open tabs of pane `index` (empty if that pane doesn't exist).
    func openTabIDs(inGroup index: Int) -> [String] { workspace.openTabs(inGroup: index) }
    /// The active tab of pane `index`.
    func activeTab(inGroup index: Int) -> String? { workspace.activeTab(inGroup: index) }
    var layout = LayoutState()
    /// Per-feature usage tally (persisted), used to re-rank the launchpad's
    /// curated feature order by how the user actually works.
    var usageStats = UsageStats()
    var toasts: [Toast] = []
    /// History of important notifications (errors, warnings, key wins), newest
    /// first. Routine success toasts are not kept.
    var notifications: [AppNotification] = []
    /// Whether the notifications side panel is open.
    var showNotifications = false
    /// Important notifications arrived since the panel was last opened.
    var unreadNotifications = 0
    var isRunningFeature = false

    // Layout toggles: ⌘B (sidebar) and ⌘J (minimize/maximize the command bar).
    var sidebarVisible = true
    var commandBarExpanded = false
    var commandBarTab: CommandBarTab = .recent
    /// Drives the first-launch / replayable welcome tour sheet.
    var presentTour = false
    /// Drives the first-launch role picker (a full-window takeover) and the
    /// "Change role" flow. Picking a role seeds a curated feature set.
    var presentRolePicker = false
    /// True while a performance/network recording is in flight — locks the
    /// device and bundle pickers so the captured series stays consistent.
    var recordingActive = false

    /// Views holding losable work (an active recording, unsaved editor edits)
    /// register a guard here, keyed by the owning tab's feature id, so closing
    /// that tab — or switching device / quitting — routes through `pendingExit`
    /// for confirmation instead of silently discarding the work. Open tabs stay
    /// mounted, so switching tabs is always safe and never consults this.
    private(set) var exitGuards: [String: ExitGuard] = [:]
    /// A navigation deferred until the user resolves the relevant `exitGuards`
    /// entry (close a guarded tab, switch device, or quit with work in flight).
    private(set) var pendingExit: PendingExit?
    /// The command bar's Terminal tab — a real PTY-backed shell, shared
    /// app-wide so it persists across features.
    let terminalSession = TerminalSession()

    /// The Reactotron server + timeline, owned here (not by the view) so leaving
    /// the feature can keep the connection alive and return to an intact session.
    let reactotronSession: ReactotronSession

    /// The JS Console (Hermes CDP) session — owned here so its log buffer and
    /// connection survive leaving the feature, like the Reactotron session.
    let jsConsoleSession: JSConsoleSession

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
    }

    // MARK: - Font scaling (⌘= / ⌘- / ⌘0)

    /// UI zoom factors ⌘=/⌘- step through (1.0 = default). macOS doesn't honor
    /// SwiftUI dynamic type, so the window content is scaled instead — which
    /// grows every font, icon, and control together and reflows the layout.
    private static let scales: [Double] = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    private static let defaultScaleIndex = 2

    /// Index into `scales`; persisted so the chosen size survives relaunch.
    var fontScaleStep = AppState.defaultScaleIndex

    /// Applied to the window content via a scaleEffect zoom.
    var fontScale: Double { Self.scales[fontScaleStep] }

    func increaseFontSize() { setFontScale(fontScaleStep + 1) }
    func decreaseFontSize() { setFontScale(fontScaleStep - 1) }
    func resetFontSize() { setFontScale(Self.defaultScaleIndex) }

    private func setFontScale(_ step: Int) {
        fontScaleStep = min(max(step, 0), Self.scales.count - 1)
        UserDefaults.standard.set(fontScaleStep, forKey: "fontScaleStep")
    }

    var bundles: [AppBundle] = []
    var selectedBundleId: String?
    var adbStatus: ToolStatus?
    var installingTool: Tool?
    /// APKs opened from Finder (double-click / Open With), handed to the Install
    /// App feature to stage for an explicit install. The view consumes (clears)
    /// it once shown.
    var pendingInstallAPKs: [URL] = []
    /// Set by RootView so hotkeys/menu bar can reopen a closed main window.
    var openMainWindow: (() -> Void)?
    /// Set by RootView; opens the floating ⌘K search palette.
    var openPalette: (() -> Void)?
    /// Bumped by the ⌘K menu command; the sidebar focuses search on change.
    var focusSearchToken = 0
    struct OperationStatus: Equatable {
        var label: String
        /// 0…1 when the total is known, nil = indeterminate.
        var fraction: Double?
    }

    /// The long-running operation in flight (pull, record, copy…) — the
    /// progress strip under the device bar reflects it.
    var runningOperation: OperationStatus?

    /// Wrap a slow operation so the UI shows what's happening (spinner).
    func withOperation<T: Sendable>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        runningOperation = OperationStatus(label: label)
        defer { runningOperation = nil }
        return try await work()
    }

    /// Wrap a pull whose destination grows on disk: progress is the local
    /// file's size against the known source size — a real percentage.
    func withFileProgress<T: Sendable>(
        _ label: String,
        destination: URL,
        expectedBytes: Int?,
        _ work: () async throws -> T
    ) async rethrows -> T {
        guard let expectedBytes, expectedBytes > 0 else {
            return try await withOperation(label, work)
        }
        runningOperation = OperationStatus(label: label, fraction: 0)
        let poller = Task { [weak self] in
            while true {
                // A plain `try?` here swallows the cancellation thrown by
                // sleep and lets one final status write land AFTER the defer
                // below has cleared the strip — leaving it stuck forever.
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let written = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int ?? 0
                self?.runningOperation = OperationStatus(
                    label: label,
                    fraction: min(1, Double(written) / Double(expectedBytes))
                )
            }
        }
        defer {
            poller.cancel()
            runningOperation = nil
        }
        return try await work()
    }

    // MARK: - Save destinations

    /// Ask where to save one pulled file. nil = user cancelled.
    func askSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = try? ScreenCaptureService.ensureCaptureDir()
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Ask for a folder to receive several pulled files. nil = cancelled.
    func askSaveFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.directoryURL = try? ScreenCaptureService.ensureCaptureDir()
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// Last result per feature id, shown inline in the detail pane.
    var lastResults: [String: (result: FeatureResult, at: Date)] = [:]
    /// Per-serial enrichment for the device picker (version, battery).
    var deviceDetails: [String: DeviceDetails] = [:]

    /// Bring the app forward, reopening the main window if it was closed.
    func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    var adbMissing: Bool { adbStatus?.installed == false }

    private var deviceStreamTask: Task<Void, Never>?
    /// Set the moment the user picks a role this session, so `bootstrap`'s
    /// async layout load can't overwrite the just-seeded curation.
    private var roleChosenThisSession = false

    init(env: AppEnvironment) {
        self.env = env
        let savedStep = UserDefaults.standard.object(forKey: "fontScaleStep") as? Int ?? Self.defaultScaleIndex
        fontScaleStep = min(max(savedStep, 0), Self.scales.count - 1)
        reactotronSession = ReactotronSession(client: env.client)
        jsConsoleSession = JSConsoleSession(adb: env.client)
        reactotronSession.app = self
        jsConsoleSession.app = self
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let prefs = await env.stores.prefs.load()
        selectedSerial = prefs.selectedSerial
        runOnAll = prefs.runOnAll
        selectedBundleId = prefs.selectedBundleId
        let loadedLayout = await env.stores.layout.load()
        // A brand-new user can pick a role — which seeds `layout` — while these
        // async store loads are still in flight; don't clobber that seed.
        if !roleChosenThisSession {
            layout = loadedLayout
            var layoutChanged = layout.adoptNewDefaults()
            layoutChanged = layout.adoptAllEnabled() || layoutChanged
            layoutChanged = layout.adoptNewRoleFeatures() || layoutChanged
            if layoutChanged {
                persistLayout()
            }
            // Reopen the tabs from the last session (idle — recordings/streams
            // don't resume). Falls back to a single Home tab for a new user or a
            // layout written before tabs existed.
            restoreTabs(from: layout)
        }
        usageStats = await env.stores.usage.load()
        bundles = await env.stores.bundles.load()
        await refreshToolStatus()

        deviceStreamTask = Task { [weak self, monitor = env.monitor] in
            // This Task inherits AppState's @MainActor isolation, so the loop
            // body already runs on the main actor — no extra hop needed.
            for await devices in await monitor.updates() {
                guard let self else { break }
                self.devicesChanged(devices)
            }
        }
    }

    func refreshToolStatus() async {
        adbStatus = await env.engine.toolDetection.detectAdb()
    }

    func installTool(_ tool: Tool) {
        guard installingTool == nil else { return }
        installingTool = tool
        Task {
            let result = await env.engine.toolDetection.installViaBrew(tool)
            showToast(Toast(message: result.message, ok: result.ok))
            await refreshToolStatus()
            installingTool = nil
        }
    }

    private func devicesChanged(_ devices: [Device]) {
        self.devices = devices
        let ready = devices.filter(\.isReady)
        // "Run on all" only makes sense with more than one device.
        if ready.count <= 1, runOnAll {
            runOnAll = false
            persistSelection()
        }
        let before = selectedSerial
        if let selectedSerial, !devices.contains(where: { $0.serial == selectedSerial }) {
            self.selectedSerial = ready.first?.serial
        } else if selectedSerial == nil {
            selectedSerial = ready.first?.serial
        }
        if selectedSerial != before || (selectedSerial != nil && activeOverrides.isEmpty) {
            Task { await refreshOverrides() }
        }
        for device in ready where deviceDetails[device.serial] == nil {
            Task {
                deviceDetails[device.serial] = await DeviceDetails.fetch(client: env.client, serial: device.serial)
            }
        }
    }

    /// Picker label with enrichment: "Pixel 7 (005F) · Android 14 · 82%".
    func deviceTitle(_ device: Device) -> String {
        guard device.isReady else {
            return device.state == "unauthorized"
                ? "\(device.label) — accept the prompt on the device"
                : "\(device.label) — \(device.state)"
        }
        var parts = [device.label]
        if let details = deviceDetails[device.serial] {
            if let version = details.androidVersion { parts.append("Android \(version)") }
            if let battery = details.batteryLevel { parts.append("\(battery)%") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Overrides

    var activeOverrides: [ActiveOverride] = []

    func refreshOverrides() async {
        guard let serial = selectedSerial, selectedDevice?.isReady == true else {
            activeOverrides = []
            return
        }
        activeOverrides = (try? await env.engine.overrides.active(serial: serial)) ?? []
    }

    func resetOverride(_ kind: OverrideKind) {
        guard let serial = selectedSerial else { return }
        let featureID = FeatureRegistry.all.first { $0.overrideKind == kind }?.id
        Task {
            await CommandLog.userInitiated(feature: featureID) {
                do {
                    try await env.engine.overrides.reset(serial: serial, kind: kind)
                    showToast(Toast(message: "\(kind.label) reset", ok: true))
                } catch {
                    showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            await refreshOverrides()
        }
    }

    func resetAllOverrides() {
        guard let serial = selectedSerial else { return }
        Task {
            await CommandLog.userInitiated {
                do {
                    try await env.engine.overrides.resetAll(serial: serial)
                    showToast(Toast(message: "All overrides reset", ok: true))
                } catch {
                    showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            await refreshOverrides()
        }
    }

    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    /// Serials a device-scoped feature should run against. The selected
    /// device always comes first so single-device views (`targetSerials
    /// .first`) show the device the bar displays, even with run-on-all on.
    var targetSerials: [String] {
        let ready = devices.filter(\.isReady)
        let selected = ready.first { $0.serial == selectedSerial }
        if runOnAll {
            var serials = ready.map(\.serial)
            if let selected, let index = serials.firstIndex(of: selected.serial) {
                serials.swapAt(0, index)
            }
            return serials
        }
        return selected.map { [$0.serial] } ?? []
    }

    func refreshDevices() {
        Task { await env.monitor.invalidate() }
    }

    /// Drop a wireless adb connection (one device, or all when `target` is nil).
    /// USB/emulator devices can't be disconnected this way — the device bar
    /// only offers this for wireless devices.
    func disconnectWireless(target: String?) {
        let connection = env.engine.connection
        Task {
            await CommandLog.userInitiated(feature: "wireless-adb") {
                do {
                    let result = try await connection.disconnect(target: target)
                    showToast(Toast(message: result.message, ok: result.ok, important: true))
                } catch {
                    showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
        }
    }

    /// Ready devices that are wireless (serial is ip:port) — eligible for
    /// the device bar's Disconnect control.
    var readyWirelessDevices: [Device] {
        devices.filter { $0.isReady && $0.isWireless }
    }

    var readyDeviceCount: Int {
        devices.filter(\.isReady).count
    }

    // MARK: - Leave guard (protect in-flight recordings / unsaved edits)

    /// Work that navigating away would destroy. `style` picks the confirmation's
    /// copy and button set: a recording offers Stop & save, an edit doesn't.
    struct ExitGuard: Equatable, Identifiable {
        enum Style: Equatable { case recording, edits }
        let id: UUID
        /// The feature id of the tab that owns this guard, so closing a tab can
        /// tell whether *its* work is the work at stake.
        var featureID: String
        var style: Style
        var title: String
        var message: String
    }

    /// A navigation held back until the user resolves the active `ExitGuard`.
    struct PendingExit: Equatable {
        enum Target: Equatable { case closeTab(String), device(String), quit }
        var target: Target
        /// Flips true when the user chooses "Stop & save": the active view runs
        /// its own save, then calls `finishExitSave()`. The dialog hides while
        /// the save is in flight.
        var saving = false
    }

    /// Register (or replace) the leave guard for a tab. A protected view calls
    /// this when losable work begins, and `clearExitGuard` when it ends.
    func setExitGuard(_ value: ExitGuard) { exitGuards[value.featureID] = value }

    /// Clear the guard identified by `id`, wherever it's keyed — so a torn-down
    /// view can't wipe a guard a newer view just registered (ids are unique).
    func clearExitGuard(_ id: UUID) {
        exitGuards = exitGuards.filter { $0.value.id != id }
    }

    /// The guard the pending leave confirmation is about: the closing tab's
    /// guard, or any active guard when switching device / quitting.
    var pendingGuard: ExitGuard? {
        switch pendingExit?.target {
        case .closeTab(let id): return exitGuards[id]
        case .device, .quit: return exitGuards.values.first
        case nil: return nil
        }
    }

    /// Whether the pending leave would destroy `featureID`'s work — true for a
    /// close of that exact tab, or any device-switch / quit (which leaves every
    /// tab). A guarded view's save-on-leave gates on this so closing one tab
    /// can't make a different tab save.
    func pendingExitConcerns(_ featureID: String) -> Bool {
        switch pendingExit?.target {
        case .closeTab(let id): return id == featureID
        case .device, .quit: return true
        case nil: return false
        }
    }

    /// Whether a tab is actively recording — drives its red pulse in the tab
    /// strip. A `.recording` guard is registered exactly while screen/mirror
    /// recording or while a performance/network capture holds unexported samples.
    func tabIsRecording(_ id: String) -> Bool {
        exitGuards[id]?.style == .recording
    }

    /// Open `id`, or refocus it wherever it's already open. Every feature open
    /// (sidebar, palette, menu, hotkeys, Finder) routes through here; a not-yet-
    /// open feature lands in the focused group. Switching is always safe (tabs
    /// stay mounted), so there's no leave guard — only the `TabState.maxTabs`
    /// total cap, which surfaces a toast when a new tab can't open.
    func requestFeature(_ id: String) {
        guard workspace.open(id) else {
            showToast(Toast(
                message: "You can have up to \(Workspace.maxTabs) tabs open — close one first.",
                ok: false))
            return
        }
        persistTabs()
    }

    /// Close a tab (in whichever pane holds it). A tab whose view holds losable
    /// work routes through the leave confirmation first, since closing unmounts
    /// the view (which would destroy that work). Closing any other is immediate.
    func closeTab(_ id: String) {
        if exitGuards[id] != nil {
            pendingExit = PendingExit(target: .closeTab(id))
        } else {
            performClose(id)
        }
    }

    /// Close the focused pane's active tab (⌘W).
    func closeActiveTab() {
        if let id = workspace.activeTab { closeTab(id) }
    }

    /// Give a pane keyboard focus — its `+` focuses it so a new tab lands there.
    func focusGroup(_ index: Int) { workspace.focus(index); persistTabs() }

    func selectNextTab() { workspace.cycleForward(); persistTabs() }
    func selectPreviousTab() { workspace.cycleBackward(); persistTabs() }
    /// Activate the tab at a 0-based index in the focused pane (⌃1–⌃9).
    func selectTab(index: Int) { workspace.activate(index: index); persistTabs() }

    /// Drag-reorder a tab within its own pane so it sits before `targetID`.
    func reorderTab(_ id: String, before targetID: String?) {
        workspace.reorder(id, before: targetID)
        persistTabs()
    }

    /// Move `id` into pane `dest` — dragging a tab to the other pane.
    func moveTab(_ id: String, toGroup dest: Int) {
        workspace.move(id, toGroup: dest)
        persistTabs()
    }

    /// Resolve a strip/pane drop: reorder within the same pane, or move to the
    /// other pane and position it at the drop target.
    func dropTab(_ id: String, intoGroup dest: Int, before targetID: String?) {
        workspace.drop(id, intoGroup: dest, before: targetID)
        persistTabs()
    }

    /// Split the workspace: move `id` into a new second pane.
    func splitTab(_ id: String) {
        workspace.split(id)
        persistTabs()
    }

    private func performClose(_ id: String) {
        workspace.close(id)
        persistTabs()
    }

    private func persistTabs() {
        layout.tabGroups = workspace.groups.map { TabGroupState(tabs: $0.openTabs, activeTab: $0.activeTab) }
        layout.focusedGroup = workspace.focusedGroup
        persistLayout()
    }

    /// Reopen persisted panes (idle — live sessions don't resume). All the
    /// trimming/validation invariants live in `Workspace`; this just supplies the
    /// registry validity check and the Home fallback.
    private func restoreTabs(from layout: LayoutState) {
        workspace = Workspace(
            restoring: layout.tabGroups ?? [],
            focusedGroup: layout.focusedGroup,
            fallback: "home",
            isValidID: Self.isValidTabID
        )
    }

    /// Ids that can back a tab: every registry feature plus the standalone
    /// Home / About / Catalog screens.
    private static func isValidTabID(_ id: String) -> Bool {
        FeatureRegistry.byID[id] != nil || ["home", "about", "catalog"].contains(id)
    }

    /// Switch the active device, or hold it behind a confirmation when a guard
    /// is active.
    func requestDevice(_ serial: String) {
        guard serial != selectedSerial else { return }
        if exitGuards.isEmpty {
            selectedSerial = serial
            persistSelection()
        } else {
            pendingExit = PendingExit(target: .device(serial))
        }
    }

    /// Called from `applicationShouldTerminate`. Returns true to quit now; false
    /// means losable work is in flight — the leave prompt is shown and the
    /// resolution drives termination (see `quitNow` / `cancelExit`).
    func requestQuit() -> Bool {
        guard !exitGuards.isEmpty else { return true }
        pendingExit = PendingExit(target: .quit)
        return false
    }

    /// "Discard" / "Discard changes": drop the at-risk work and run the deferred
    /// navigation. A tab close clears just that tab's guard (and its view aborts
    /// in `.onDisappear` as it unmounts); a device-switch / quit leaves every
    /// tab, so clear them all and let each view abort.
    func discardAndExit() {
        switch pendingExit?.target {
        case .closeTab(let id): exitGuards[id] = nil
        case .device, .quit: exitGuards.removeAll()
        case nil: break
        }
        performPendingExit()
    }

    /// "Keep recording" / "Keep editing": abandon the pending navigation.
    func cancelExit() {
        let wasQuit = pendingExit?.target == .quit
        pendingExit = nil
        if wasQuit { NSApp.reply(toApplicationShouldTerminate: false) }
    }

    /// "Stop & save": ask the active view to save (it observes `pendingExit`),
    /// keeping the dialog hidden until it calls `finishExitSave()`.
    func beginExitSave() { pendingExit?.saving = true }

    /// Called by the active view once its save-on-leave finished, to proceed.
    func finishExitSave() { performPendingExit() }

    private func performPendingExit() {
        guard let pending = pendingExit else { return }
        pendingExit = nil
        switch pending.target {
        case .closeTab(let id): performClose(id)
        case .device(let serial): selectedSerial = serial; persistSelection()
        case .quit: quitNow()
        }
    }

    /// Finish a deferred quit: tear down a kept-alive Reactotron session (as the
    /// normal quit path does), then let termination proceed.
    private func quitNow() {
        Task {
            if reactotronSession.isRunning { await reactotronSession.stopForQuit() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: - Feature running

    /// Open or run a feature from a launch surface (launchpad or sidebar),
    /// recording the engagement for adaptive ranking. Instant/toggle actions
    /// that need no screen fire in place (recorded inside `run`); everything
    /// else opens its detail pane.
    func openFeature(_ feature: FeatureDef) {
        if feature.firesWithoutScreen {
            Task { await run(feature: feature, params: [:]) }
        } else {
            noteFeatureUse(feature.id)
            requestFeature(feature.id)
        }
    }

    /// Record one engagement with a feature, persisted for adaptive launchpad
    /// ranking across launches.
    func noteFeatureUse(_ featureID: String) {
        usageStats.record(featureID, at: Date())
        persistUsage()
    }

    func run(feature: FeatureDef, params: [String: FeatureValue]) async {
        isRunningFeature = true
        defer { isRunningFeature = false }
        Telemetry.shared.track("feature_used", ["feature": feature.id])
        noteFeatureUse(feature.id)

        // A screenshot from a quick path (sidebar ⏎, global hotkey, menu bar)
        // captures and saves straight to the capture folder; the Screenshot
        // view instead opens the capture in the editor and saves on demand.
        if feature.id == "screenshot" {
            await runScreenshot()
            return
        }

        var params = params
        // A state-override fired without an explicit target flips its current
        // state — so a sidebar tap, hotkey, or ⌘K toggles it in place with no
        // detail screen (the sidebar switch reflects the result).
        if feature.isStateOverride, params["on"] == nil, let kind = feature.overrideKind {
            params["on"] = .bool(!activeOverrides.contains { $0.kind == kind })
        }
        if feature.needsBundle {
            guard let bundle = selectedBundle else {
                showToast(Toast(message: "Pick a saved bundle first.", ok: false))
                return
            }
            params["packageId"] = .string(bundle.packageId)
        } else if params["packageId"] == nil, let bundle = selectedBundle {
            // Optional context for features like bug-report that include app
            // info when a bundle happens to be selected.
            params["packageId"] = .string(bundle.packageId)
        }

        let engine = env.engine
        await CommandLog.userInitiated(feature: feature.id) {
            if !feature.needsDevice {
                let result = await engine.run(featureID: feature.id, serial: "", params: params)
                self.lastResults[feature.id] = (result, Date())
                self.show(result)
                return
            }

            let targets = self.targetSerials
            guard !targets.isEmpty else {
                self.showToast(Toast(message: "No device connected.", ok: false))
                return
            }
            for serial in targets {
                let result = await engine.run(featureID: feature.id, serial: serial, params: params)
                self.lastResults[feature.id] = (result, Date())
                if targets.count > 1 {
                    let label = self.devices.first { $0.serial == serial }?.label ?? serial
                    self.show(FeatureResult(
                        ok: result.ok,
                        message: "\(label): \(result.message)",
                        copyText: result.copyText,
                        revealPath: result.revealPath
                    ))
                } else {
                    self.show(result)
                }
            }
        }
        if feature.isStateOverride {
            await refreshOverrides()
        }
    }

    private func show(_ result: FeatureResult) {
        // A result that carries copyText (Copy Device IP, Copy Foreground
        // Bundle ID, Copy Current Activity) lands on the clipboard immediately — the
        // point of these actions — so a sidebar click is all it takes.
        var message = result.message
        if let copyText = result.copyText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText, forType: .string)
            message += " · copied"
        }
        showToast(Toast(
            message: message,
            ok: result.ok,
            copyText: result.copyText,
            revealPath: result.revealPath
        ))
    }

    /// Route APKs opened from Finder to the Install App feature: surface the main
    /// window, stage the files there, and select the feature so the user confirms
    /// the target device and installs.
    func openAPKs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingInstallAPKs = urls
        activateMainWindow()
        // Route through the leave guard like every other feature switch: opening
        // an APK from Finder mid-recording (or with unsaved edits) must raise the
        // confirmation, not silently abandon that work. The staged APKs wait in
        // `pendingInstallAPKs` and are consumed once Install App actually appears.
        requestFeature("install-app")
    }

    /// Install one or more APKs on the given device serials, one toast per APK
    /// (failures keep the full adb output in the toast's copyText). Returns a
    /// short multi-line summary for inline display. Shared by the Install App
    /// screen's drop zone, the file picker, and APKs opened from Finder.
    @discardableResult
    func installAPKs(_ urls: [URL], onSerials serials: [String]) async -> String {
        guard !urls.isEmpty, !serials.isEmpty else { return "" }
        var report: [String] = []
        await CommandLog.userInitiated(feature: "install-app") {
            for url in urls {
                let name = url.lastPathComponent
                var ok = 0
                var failures: [(serial: String, result: FeatureResult)] = []
                for serial in serials {
                    let result = (try? await env.engine.appInstall.install(apkPath: url.path, serial: serial))
                        ?? FeatureResult(ok: false, message: "adb not found")
                    if result.ok { ok += 1 } else { failures.append((serial, result)) }
                }
                showToast(Self.installToast(name: name, ok: ok, total: serials.count, failures: failures))
                report.append(ok == serials.count
                    ? "Installed \(name)"
                    : "Installed \(name) on \(ok) of \(serials.count) devices")
            }
        }
        return report.joined(separator: "\n")
    }

    /// A short install headline for the toast; on failure the full adb output is
    /// kept in `copyText` so the notifications panel carries the detail without
    /// dumping it into the transient toast.
    private static func installToast(
        name: String, ok: Int, total: Int, failures: [(serial: String, result: FeatureResult)]
    ) -> Toast {
        if failures.isEmpty {
            let message = total == 1 ? "Installed \(name)" : "Installed \(name) on \(total) devices"
            return Toast(message: message, ok: true)
        }
        let message = total == 1
            ? "Couldn't install \(name) — \(failures[0].result.message)"
            : "Installed \(name) on \(ok)/\(total) devices — \(failures.count) failed"
        let detail = failures
            .map { failure in
                let body = failure.result.copyText ?? failure.result.message
                return total == 1 ? body : "\(failure.serial): \(body)"
            }
            .joined(separator: "\n\n")
        return Toast(message: message, ok: false, copyText: detail.isEmpty ? nil : detail)
    }

    func showToast(_ toast: Toast) {
        toasts.append(toast)
        if toast.important {
            notifications.insert(
                AppNotification(
                    id: toast.id,
                    message: toast.message,
                    level: toast.level,
                    copyText: toast.copyText,
                    revealPath: toast.revealPath,
                    date: Date()
                ),
                at: 0
            )
            if notifications.count > 200 {
                notifications.removeLast(notifications.count - 200)
            }
            if !showNotifications { unreadNotifications += 1 }
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            toasts.removeAll { $0.id == toast.id }
        }
    }

    func toggleNotifications() {
        showNotifications.toggle()
        if showNotifications { unreadNotifications = 0 }
    }

    func clearNotifications() {
        notifications.removeAll()
    }

    func dismissNotification(_ id: UUID) {
        notifications.removeAll { $0.id == id }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: - Role

    /// Apply the user's role choice (first-run or "Change role"): curate the
    /// enabled set + sidebar order to that role, or keep everything on for
    /// `nil` ("show me everything"). Persists and lands on the launchpad.
    func chooseRole(_ role: UserRole?) {
        if let role {
            layout.seedRole(role)
        } else {
            layout.seedEverything()
        }
        roleChosenThisSession = true
        // Start the freshly-chosen role on a single Home tab, no split.
        workspace.reset()
        persistTabs()
        presentRolePicker = false
    }

    /// The user's current role, nil when they chose "show me everything".
    var selectedRole: UserRole? {
        layout.selectedRole.flatMap(UserRole.init(rawValue:))
    }

    private func persistUsage() {
        let snapshot = usageStats
        Task {
            try? await env.stores.usage.save(snapshot)
        }
    }

    // MARK: - Bundles

    var selectedBundle: AppBundle? {
        bundles.first { $0.id == selectedBundleId }
    }

    func addBundle(nickname: String, packageId: String) {
        let bundle = AppBundle(
            nickname: nickname.isEmpty ? packageId : nickname,
            packageId: packageId,
            createdAt: Date().timeIntervalSince1970 * 1000
        )
        bundles.append(bundle)
        selectBundle(bundle.id)
        persistBundles()
    }

    func updateBundle(_ bundle: AppBundle) {
        guard let index = bundles.firstIndex(where: { $0.id == bundle.id }) else { return }
        bundles[index] = bundle
        persistBundles()
    }

    func removeBundle(id: String) {
        bundles.removeAll { $0.id == id }
        if selectedBundleId == id {
            selectBundle(bundles.first?.id)
        }
        persistBundles()
    }

    func selectBundle(_ id: String?) {
        selectedBundleId = id
        Task {
            try? await env.stores.prefs.update { $0.selectedBundleId = id }
        }
    }

    private func persistBundles() {
        let snapshot = bundles
        Task {
            try? await env.stores.bundles.save(snapshot)
        }
    }

    /// Quick capture (sidebar ⏎, global hotkey, menu bar): grab and save
    /// straight to the capture folder — no dialog. An optional delay gives you
    /// time to arrange the device screen first. The Screenshot view itself uses
    /// `captureForEditor` instead, opening the shot for markup before saving.
    func runScreenshot(delaySeconds: Int = 0) async {
        guard let serial = targetSerials.first else {
            showToast(Toast(message: "No device connected.", ok: false))
            return
        }
        if delaySeconds > 0 {
            showToast(Toast(message: "Capturing in \(delaySeconds)s…", ok: true))
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
        await CommandLog.userInitiated(feature: "screenshot") {
            do {
                let dir = try ScreenCaptureService.ensureCaptureDir()
                let dest = dir.appendingPathComponent("screenshot_\(ScreenCaptureService.stamp()).png")
                let file = try await withOperation("Capturing screenshot…") {
                    try await env.engine.captureScreenshot(serial: serial, to: dest)
                }
                let result = FeatureResult(ok: true, message: "Screenshot saved", revealPath: file.path)
                lastResults["screenshot"] = (result, Date())
                showToast(Toast(message: "Screenshot saved to \(dir.lastPathComponent)", ok: true, revealPath: file.path))
            } catch {
                lastResults["screenshot"] = (FeatureResult(ok: false, message: error.localizedDescription), Date())
                showToast(Toast(message: error.localizedDescription, ok: false))
            }
        }
    }

    /// Capture for the in-app editor — returns the image without writing it
    /// anywhere; the editor saves or copies on demand. The delay lets you
    /// arrange the device screen first.
    func captureForEditor(delaySeconds: Int = 0) async -> NSImage? {
        guard let serial = targetSerials.first else {
            showToast(Toast(message: "No device connected.", ok: false))
            return nil
        }
        if delaySeconds > 0 {
            showToast(Toast(message: "Capturing in \(delaySeconds)s…", ok: true))
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
        let data: Data? = await CommandLog.userInitiated(feature: "screenshot") {
            do {
                return try await withOperation("Capturing screenshot…") {
                    try await env.engine.captureScreenshotData(serial: serial)
                }
            } catch {
                showToast(Toast(message: error.localizedDescription, ok: false))
                return nil
            }
        }
        return data.flatMap { NSImage(data: $0) }
    }

    // MARK: - Quick actions

    /// Grab the package id of the app on the device screen and save/select
    /// it as a bundle in one step.
    func adoptForegroundApp() {
        guard let serial = targetSerials.first else {
            showToast(Toast(message: "No device connected.", ok: false))
            return
        }
        Task {
            await CommandLog.userInitiated {
                guard let packageId = try? await env.engine.inspection.getForegroundPackage(serial: serial) else {
                    showToast(Toast(message: "Couldn't read the foreground app — is the screen on?", ok: false))
                    return
                }
                if let existing = bundles.first(where: { $0.packageId == packageId }) {
                    selectBundle(existing.id)
                    showToast(Toast(message: "Selected \(existing.nickname)", ok: true))
                } else {
                    let nickname = packageId.split(separator: ".").last.map(String.init)?.capitalized ?? packageId
                    addBundle(nickname: nickname, packageId: packageId)
                    showToast(Toast(message: "Saved \(nickname) (\(packageId))", ok: true))
                }
            }
        }
    }

    func installAdbKeyboard() {
        guard let serial = targetSerials.first else { return }
        showToast(Toast(message: "Downloading ADBKeyboard…", ok: true))
        Task {
            await CommandLog.userInitiated(feature: "send-text") {
                let result = await env.engine.adbKeyboard.install(serial: serial)
                showToast(Toast(message: result.message, ok: result.ok))
            }
        }
    }

    // MARK: - Persistence

    func persistSelection() {
        let serial = selectedSerial
        let all = runOnAll
        Task {
            try? await env.stores.prefs.update {
                $0.selectedSerial = serial
                $0.runOnAll = all
            }
        }
    }
}
