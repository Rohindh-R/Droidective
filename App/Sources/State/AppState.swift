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

    var devices: [Device] = []
    var selectedSerial: String?
    var runOnAll = false
    var searchText = ""
    var selectedFeatureID: String?
    var layout = LayoutState()
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
    /// True while a performance/network recording is in flight — locks the
    /// device and bundle pickers so the captured series stays consistent.
    var recordingActive = false
    /// The command bar's Terminal tab — a real PTY-backed shell, shared
    /// app-wide so it persists across features.
    let terminalSession = TerminalSession()

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

    init(env: AppEnvironment) {
        self.env = env
        let savedStep = UserDefaults.standard.object(forKey: "fontScaleStep") as? Int ?? Self.defaultScaleIndex
        fontScaleStep = min(max(savedStep, 0), Self.scales.count - 1)
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let prefs = await env.stores.prefs.load()
        selectedSerial = prefs.selectedSerial
        runOnAll = prefs.runOnAll
        selectedBundleId = prefs.selectedBundleId
        let restoreLast = UserDefaults.standard.object(forKey: "restoreLastFeature") as? Bool ?? true
        if restoreLast, let last = prefs.lastFeatureId, FeatureRegistry.byID[last] != nil {
            selectedFeatureID = last
        }
        layout = await env.stores.layout.load()
        var layoutChanged = layout.adoptNewDefaults()
        layoutChanged = layout.adoptAllEnabled() || layoutChanged
        if layoutChanged {
            persistLayout()
        }
        bundles = await env.stores.bundles.load()
        await refreshToolStatus()

        deviceStreamTask = Task { [weak self, monitor = env.monitor] in
            for await devices in await monitor.updates() {
                guard let self else { break }
                await MainActor.run { self.devicesChanged(devices) }
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

    /// Enabled features shown on the sidebar, in display order (registry order
    /// within categories). Hub members are excluded — they're managed from
    /// their hub screen, never as standalone sidebar rows — but stay reachable
    /// via search (`disabledMatches`) and hotkeys.
    var enabledFeatures: [FeatureDef] {
        let enabled = layout.effectiveEnabledIDs
        return FeatureRegistry.all.filter { enabled.contains($0.id) && !$0.isAbsorbedByHub }
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

    /// Enabled, non-pinned features in the user's order. Drives the flat
    /// (ungrouped) sidebar and its drag-to-reorder.
    var orderedEnabledFeatures: [FeatureDef] {
        ordered(enabledFeatures.filter { !layout.favorites.contains($0.id) })
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

    // MARK: - Feature running

    func run(feature: FeatureDef, params: [String: FeatureValue]) async {
        isRunningFeature = true
        defer { isRunningFeature = false }
        Telemetry.shared.track("feature_used", ["feature": feature.id])

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

    /// Move a feature to `toIndex` within its group (sidebar drag-and-drop).
    /// `toIndex` is the insertion position in the group's enabled-feature list
    /// (0 = top, count = end).
    func moveFeature(_ id: String, toIndex: Int, in category: FeatureCategory) {
        let group = enabledFeatures(in: category)
        guard let from = group.firstIndex(where: { $0.id == id }) else { return }
        reorderFeatures(group, from: IndexSet(integer: from), to: toIndex)
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

    func persistLastFeature() {
        let id = selectedFeatureID
        Task {
            try? await env.stores.prefs.update { $0.lastFeatureId = id }
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
