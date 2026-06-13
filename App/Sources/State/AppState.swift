import ADBKit
import AppKit
import Foundation
import Observation

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let ok: Bool
    var copyText: String?
    var revealPath: String?
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
    var isRunningFeature = false

    var bundles: [AppBundle] = []
    var selectedBundleId: String?
    var adbStatus: ToolStatus?
    var scrcpyStatus: ToolStatus?
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
    /// featureId → run count (persisted; drives the Frequent section).
    var runCounts: [String: Int] = [:]
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
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let prefs = await env.stores.prefs.load()
        selectedSerial = prefs.selectedSerial
        runOnAll = prefs.runOnAll
        selectedBundleId = prefs.selectedBundleId
        runCounts = prefs.runCounts ?? [:]
        let restoreLast = UserDefaults.standard.object(forKey: "restoreLastFeature") as? Bool ?? true
        if restoreLast, let last = prefs.lastFeatureId, FeatureRegistry.byID[last] != nil {
            selectedFeatureID = last
        }
        layout = await env.stores.layout.load()
        if layout.adoptNewDefaults() {
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
        let status = await env.engine.toolDetection.detect()
        adbStatus = status.adb
        scrcpyStatus = status.scrcpy
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
        Task {
            await CommandLog.$isUserInitiated.withValue(true) {
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
            await CommandLog.$isUserInitiated.withValue(true) {
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

    /// Enabled features in display order (registry order within categories).
    var enabledFeatures: [FeatureDef] {
        let enabled = layout.effectiveEnabledIDs
        return FeatureRegistry.all.filter { enabled.contains($0.id) }
    }

    var visibleFeatures: [FeatureDef] {
        enabledFeatures.filter { $0.matches(searchText) }
    }

    /// Disabled features matching the current search (shown in their own
    /// sidebar section, runnable without enabling).
    var disabledMatches: [FeatureDef] {
        let enabled = layout.effectiveEnabledIDs
        return FeatureRegistry.all.filter { !enabled.contains($0.id) && $0.matches(searchText) }
    }

    var hiddenFeatureCount: Int {
        FeatureRegistry.all.count - enabledFeatures.count
    }

    func refreshDevices() {
        Task { await env.monitor.invalidate() }
    }

    // MARK: - Feature running

    /// Top non-favorite features by run count, for the Frequent section.
    var frequentFeatures: [FeatureDef] {
        let enabled = layout.effectiveEnabledIDs
        return runCounts
            .filter { $0.value >= 2 && enabled.contains($0.key) && !layout.favorites.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .compactMap { FeatureRegistry.byID[$0.key] }
    }

    func run(feature: FeatureDef, params: [String: FeatureValue]) async {
        isRunningFeature = true
        defer { isRunningFeature = false }

        runCounts[feature.id, default: 0] += 1
        let counts = runCounts
        Task {
            try? await env.stores.prefs.update { $0.runCounts = counts }
        }

        // Screenshot always asks where to save, whichever entry point ran it
        // (sidebar ⏎, hotkey, menu bar, or the Screenshot view).
        if feature.id == "screenshot" {
            await runScreenshot()
            return
        }

        var params = params
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
        await CommandLog.$isUserInitiated.withValue(true) {
            if engine.scope(for: feature.id) == .global || !feature.needsDevice {
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
        showToast(Toast(
            message: result.message,
            ok: result.ok,
            copyText: result.copyText,
            revealPath: result.revealPath
        ))
    }

    func showToast(_ toast: Toast) {
        toasts.append(toast)
        Task {
            try? await Task.sleep(for: .seconds(5))
            toasts.removeAll { $0.id == toast.id }
        }
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

    /// Back to the registry's out-of-box enabled set (favorites untouched).
    func restoreDefaultFeatures() {
        layout.enabledIds = nil
        persistLayout()
        showToast(Toast(message: "Default feature set restored", ok: true))
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

    /// Capture → ask for a location → save. Records the result so the
    /// Screenshot view's preview updates regardless of entry point.
    func runScreenshot() async {
        guard let serial = targetSerials.first else {
            showToast(Toast(message: "No device connected.", ok: false))
            return
        }
        guard let dest = askSaveLocation(suggestedName: "screenshot_\(ScreenCaptureService.stamp()).png") else {
            return
        }
        await CommandLog.$isUserInitiated.withValue(true) {
            do {
                let file = try await withOperation("Capturing screenshot…") {
                    try await env.engine.captureScreenshot(serial: serial, to: dest)
                }
                let result = FeatureResult(ok: true, message: "Screenshot saved", revealPath: file.path)
                lastResults["screenshot"] = (result, Date())
                showToast(Toast(message: result.message, ok: true, revealPath: file.path))
            } catch {
                lastResults["screenshot"] = (FeatureResult(ok: false, message: error.localizedDescription), Date())
                showToast(Toast(message: error.localizedDescription, ok: false))
            }
        }
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
            await CommandLog.$isUserInitiated.withValue(true) {
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
            await CommandLog.$isUserInitiated.withValue(true) {
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
