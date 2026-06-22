import ADBKit
import AppKit
import SwiftUI

/// Every installed app (user + system) with search across name, version,
/// and bundle id. Selecting one shows its info, permission count, and live
/// permission toggles.
struct AppsExplorerView: View {
    @Environment(AppState.self) private var state
    @State private var apps: [AppListing]?
    @State private var states: [String: AppLifecycle] = [:]
    @State private var search = ""
    @State private var scope = Scope.user
    @State private var selectedPackage: String?
    /// Packages an uninstall attempt proved can't actually be removed (it
    /// reported success but the package stayed). Their Uninstall button is
    /// dropped, leaving Disable.
    @State private var notRemovable: Set<String> = []

    enum Scope: String, CaseIterable {
        case all = "All"
        case user = "User"
        case system = "System"
    }

    private var serial: String { state.targetSerials.first ?? "" }

    private var visibleApps: [AppListing] {
        (apps ?? []).filter { app in
            switch scope {
            case .all: break
            case .user: if app.isSystem { return false }
            case .system: if !app.isSystem { return false }
            }
            return app.matches(search)
        }
    }

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to browse its apps.")
                )
            } else {
                content
            }
        }
        .task(id: state.targetSerials.first ?? "") {
            await loadApps()
        }
    }

    // Plain HStack, not HSplitView: NSSplitView ignores SwiftUI safe-area
    // insets, so the search/filter row and the detail's top rows rendered
    // underneath the device bar.
    private var content: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Search name, version, or bundle…", text: $search)
                        .brandField()
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Button {
                        Task { await loadApps(showLoading: false) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
                .padding(8)
                Divider()

                if let apps {
                    if visibleApps.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(visibleApps, selection: $selectedPackage) { app in
                            HStack(spacing: 8) {
                                AppIconView(packageId: app.packageId, name: app.displayName, serial: serial)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(app.displayName)
                                        if app.isSystem {
                                            Text("system")
                                                .font(.caption2)
                                                .foregroundStyle(.textMuted)
                                                .padding(.horizontal, 4)
                                                .background(Color.bgSurface, in: Capsule())
                                        }
                                        lifecycleBadge(for: app.packageId)
                                    }
                                    Text("\(app.packageId)\(app.versionName.map { " · v\($0)" } ?? "")")
                                        .font(.footnote)
                                        .foregroundStyle(.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            .tag(app.packageId)
                        }
                        .frame(minWidth: 260)
                    }
                    HStack {
                        Text("\(visibleApps.count) of \(apps.count) apps")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(6)
                } else {
                    ProgressView("Reading apps…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 320)

            Divider()

            if let selectedPackage {
                AppDetailPane(
                    packageId: selectedPackage,
                    lifecycle: states[selectedPackage],
                    canUninstall: canUninstall(selectedPackage),
                    onNotRemovable: { notRemovable.insert($0) },
                    onChanged: { Task { await loadApps(showLoading: false) } }
                )
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "Select an app",
                    systemImage: "square.grid.3x3",
                    description: Text("Pick an app to see its info and permissions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func lifecycleBadge(for packageId: String) -> some View {
        if let lifecycle = states[packageId], lifecycle.removed {
            badge("removed", .red)
        } else if let lifecycle = states[packageId], lifecycle.disabled {
            badge("disabled", .orange)
        }
    }

    /// Whether to offer Uninstall. The framework package and auto-generated
    /// resource overlays are never removable; the rest are offered until an
    /// attempt proves otherwise.
    private func canUninstall(_ packageId: String) -> Bool {
        if notRemovable.contains(packageId) { return false }
        if packageId == "android" { return false }
        if packageId.contains("auto_generated_rro") || packageId.hasSuffix(".overlay") { return false }
        return true
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func loadApps(showLoading: Bool = true) async {
        if showLoading {
            apps = nil
            selectedPackage = nil
        }
        guard let serial = state.targetSerials.first else { return }
        let (listing, lifecycle) = await CommandLog.userInitiated(feature: "apps") {
            async let listing = try? state.env.engine.appsExplorer.listAll(serial: serial)
            async let lifecycle = state.env.engine.systemApps.states(serial: serial)
            return await (listing, lifecycle)
        }
        guard !Task.isCancelled else { return }
        apps = listing ?? []
        states = lifecycle
    }
}

/// Right pane: app info, permission count, and live permission toggles.
private struct AppDetailPane: View {
    @Environment(AppState.self) private var state
    let packageId: String
    var lifecycle: AppLifecycle?
    var canUninstall = true
    var onNotRemovable: (String) -> Void = { _ in }
    var onChanged: () -> Void = {}

    private var derivedName: String {
        packageId.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? packageId
    }

    @State private var info: AppInfo?
    @State private var permissions: [PermissionEntry]?
    @State private var showPermissions = false
    @State private var mutating = false
    @State private var pullingApk = false
    @State private var managing = false
    @State private var showFiles = false
    @State private var confirmingClearData = false

    private var serial: String { state.targetSerials.first ?? "" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIconView(packageId: packageId, name: derivedName, serial: state.targetSerials.first ?? "")
                        .frame(width: 40, height: 40)
                    Text(packageId)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if let info, info.installed {
                    LabeledContent("Version", value: info.versionName)
                    LabeledContent("Target SDK", value: info.targetSdk)
                    LabeledContent("Min SDK", value: info.minSdk)
                    LabeledContent("Last Update", value: info.lastUpdate)
                    if let size = info.apkSizeBytes {
                        LabeledContent("APK Size", value: ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file
                        ))
                    }
                } else if info == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading app info…").foregroundStyle(.textMuted)
                    }
                }
            }

            Section("Controls") {
                HStack(spacing: 8) {
                    Button { runControl(.open) } label: {
                        Label("Open", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { runControl(.stop) } label: {
                        Label("Force Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    Button { runControl(.clearCache) } label: {
                        Label("Clear Cache", systemImage: "internaldrive")
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(managing)
            }

            Section {
                if let permissions {
                    Toggle(isOn: $showPermissions) {
                        Text("Runtime permissions (\(permissions.count))")
                    }
                    .toggleStyle(.button)
                    if showPermissions {
                        if permissions.isEmpty {
                            Text("No runtime permissions declared.")
                                .foregroundStyle(.textMuted)
                        }
                        ForEach(permissions) { permission in
                            Toggle(isOn: Binding(
                                get: { permission.granted },
                                set: { setPermission(permission, granted: $0) }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(permission.shortName)
                                    Text(permission.name)
                                        .font(.caption)
                                        .foregroundStyle(.textMuted)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(mutating)
                            .opacity(mutating ? 0.5 : 1)
                        }
                        if mutating {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Updating…").foregroundStyle(.textMuted)
                            }
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading permissions…").foregroundStyle(.textMuted)
                    }
                }
            }

            Section {
                Button {
                    pullApk()
                } label: {
                    Label(pullingApk ? "Pulling…" : "Pull APK", systemImage: "arrow.down.circle")
                }
                .disabled(pullingApk)
                Button {
                    showFiles = true
                } label: {
                    Label("Explore files", systemImage: "folder")
                }
            }

            Section("Manage") {
                if lifecycle?.removed == true {
                    Button {
                        manage { try await $0.setRemoved(serial: serial, packageId: packageId, false) }
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.left")
                    }
                    .disabled(managing)
                } else {
                    let isDisabled = lifecycle?.disabled ?? false
                    Button {
                        manage { try await $0.setDisabled(serial: serial, packageId: packageId, !isDisabled) }
                    } label: {
                        Label(isDisabled ? "Enable" : "Disable", systemImage: isDisabled ? "eye" : "eye.slash")
                    }
                    .disabled(managing)
                    Button(role: .destructive) {
                        confirmingClearData = true
                    } label: {
                        Label("Clear Data", systemImage: "trash")
                    }
                    .disabled(managing)
                    if canUninstall {
                        Button(role: .destructive) {
                            uninstall()
                        } label: {
                            Label("Uninstall", systemImage: "trash")
                        }
                        .disabled(managing)
                    }
                }
                if managing {
                    HStack { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.textMuted) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog(
            "Clear all data for \(packageId)? This signs you out and wipes local storage.",
            isPresented: $confirmingClearData
        ) {
            Button("Clear Data", role: .destructive) { runControl(.clearData) }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: "\(packageId)|\(state.targetSerials.first ?? "")") {
            await load()
        }
        .sheet(isPresented: $showFiles) {
            VStack(spacing: 0) {
                HStack {
                    Text("Files · \(packageId)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Done") { showFiles = false }
                }
                .padding(12)
                Divider()
                SandboxBrowserView(packageId: packageId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 580, height: 460)
        }
    }

    /// Uninstall-for-user, then verify it actually went away — protected system
    /// apps report success but the package manager keeps them. When it didn't
    /// stick, flag it non-removable so the button disappears.
    private func uninstall() {
        managing = true
        Task {
            await CommandLog.userInitiated(feature: "apps") {
                do {
                    _ = try await state.env.engine.systemApps.setRemoved(serial: serial, packageId: packageId, true)
                    let removed = await state.env.engine.systemApps.states(serial: serial)[packageId]?.removed ?? false
                    if removed {
                        state.showToast(Toast(message: "\(packageId) uninstalled for this user", ok: true, important: true))
                    } else {
                        onNotRemovable(packageId)
                        state.showToast(Toast(message: "Can't uninstall \(packageId) — it's protected. Disable it instead.", ok: false))
                    }
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            managing = false
            onChanged()
        }
    }

    private func manage(_ operation: @escaping (SystemAppsService) async throws -> AdbResult) {
        managing = true
        Task {
            await CommandLog.userInitiated(feature: "apps") {
                do {
                    let result = try await operation(state.env.engine.systemApps)
                    let ok = result.succeeded && !result.stdout.localizedCaseInsensitiveContains("failure")
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    state.showToast(Toast(message: ok ? "\(packageId) updated" : "Failed — \(detail)", ok: ok))
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            managing = false
            onChanged()
        }
    }

    /// Lifecycle control (open, force-stop, clear cache/data) on the selected
    /// app — the actions the standalone "Manage App" screen used to host, now
    /// folded into the Apps explorer.
    private func runControl(_ action: AppControlService.AppAction) {
        managing = true
        Task {
            await CommandLog.userInitiated(feature: "apps") {
                let result = (try? await state.env.engine.appControl.control(
                    serial: serial, packageId: packageId, action: action
                )) ?? FeatureResult(ok: false, message: "adb not found")
                state.showToast(Toast(message: result.message, ok: result.ok))
            }
            managing = false
        }
    }

    private func load() async {
        info = nil
        permissions = nil
        guard let serial = state.targetSerials.first else { return }
        let (fetchedInfo, fetchedPermissions) = await CommandLog.userInitiated(feature: "apps") {
            async let infoResult = try? state.env.engine.inspection.getAppInfo(serial: serial, packageId: packageId)
            async let permissionsResult = try? state.env.engine.inspection.listPermissions(serial: serial, packageId: packageId)
            return await (infoResult, permissionsResult)
        }
        guard !Task.isCancelled else { return }
        info = fetchedInfo ?? .notInstalled
        permissions = fetchedPermissions ?? []
    }

    private func pullApk() {
        guard let serial = state.targetSerials.first else { return }
        guard let dest = state.askSaveLocation(suggestedName: "\(packageId).apk") else { return }
        pullingApk = true
        Task {
            await CommandLog.userInitiated(feature: "apps") {
                do {
                    let saved = try await state.withFileProgress(
                        "Pulling \(packageId)…", destination: dest, expectedBytes: info?.apkSizeBytes
                    ) {
                        try await state.env.engine.inspection.pullApk(serial: serial, packageId: packageId, to: dest)
                    }
                    state.showToast(Toast(message: "APK saved", ok: true, revealPath: saved.path))
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            pullingApk = false
        }
    }

    private func setPermission(_ permission: PermissionEntry, granted: Bool) {
        guard let serial = state.targetSerials.first else { return }
        mutating = true
        Task {
            await CommandLog.userInitiated(feature: "apps") {
                let result = (try? await state.env.engine.inspection.setPermission(
                    serial: serial, packageId: packageId, permission: permission.name, grant: granted
                )) ?? FeatureResult(ok: false, message: "adb not found")
                state.showToast(Toast(message: result.message, ok: result.ok))
            }
            let refreshed = try? await state.env.engine.inspection.listPermissions(serial: serial, packageId: packageId)
            permissions = refreshed ?? permissions
            mutating = false
        }
    }
}

/// App launcher icon with a monogram fallback. Real icons are streamed off the
/// device (only the icon entry, never the whole APK) and cached; apps that ship
/// no raster icon keep the monogram.
struct AppIconView: View {
    @Environment(AppState.self) private var state
    let packageId: String
    let name: String
    let serial: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                MonogramIcon(name: name, seed: packageId)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: packageId) { await load() }
    }

    private func load() async {
        // Reset to *this* package's cached icon (nil when it has none) so a
        // reused view never lingers on the previously shown app's icon.
        image = AppIconCache.shared.image(for: packageId)
        if image != nil { return }
        guard !serial.isEmpty, !AppIconCache.shared.didAttempt(packageId) else { return }
        let data = await state.env.engine.appIcons.iconData(serial: serial, packageId: packageId)
        AppIconCache.shared.markAttempted(packageId)
        guard !Task.isCancelled else { return }
        if let data, let loaded = NSImage(data: data) {
            AppIconCache.shared.store(loaded, for: packageId)
            image = loaded
        }
    }
}

/// Colored rounded square with the app's initial — the launcher-style fallback
/// shown until (or instead of) a real icon.
struct MonogramIcon: View {
    let name: String
    let seed: String

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color.gradient)
            .overlay(
                Text(initial)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            )
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color {
        // Deterministic hue from the package id — String.hashValue is randomized
        // per process, so roll a stable hash for a consistent color.
        let hash = seed.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return Color(hue: Double(abs(hash) % 360) / 360, saturation: 0.45, brightness: 0.65)
    }
}

/// Process-lifetime cache of decoded icons, shared across rows so scrolling
/// never refetches. `attempted` remembers icon-less apps so their rows don't
/// re-probe the device each time they reappear.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private var images: [String: NSImage] = [:]
    private var attempted: Set<String> = []

    func image(for packageId: String) -> NSImage? { images[packageId] }
    func store(_ image: NSImage, for packageId: String) { images[packageId] = image }
    func didAttempt(_ packageId: String) -> Bool { attempted.contains(packageId) }
    func markAttempted(_ packageId: String) { attempted.insert(packageId) }
}
