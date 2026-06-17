import ADBKit
import AppKit
import SwiftUI

/// Every installed app (user + system) with search across name, version,
/// and bundle id. Selecting one shows its info, permission count, and live
/// permission toggles.
struct AppsExplorerView: View {
    @Environment(AppState.self) private var state
    @State private var apps: [AppListing]?
    @State private var search = ""
    @State private var scope = Scope.user
    @State private var selectedPackage: String?

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
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
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
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    Text("\(app.packageId)\(app.versionName.map { " · v\($0)" } ?? "")")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
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
                AppDetailPane(packageId: selectedPackage)
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

    private func loadApps() async {
        apps = nil
        selectedPackage = nil
        guard let serial = state.targetSerials.first else { return }
        let result = await CommandLog.userInitiated(feature: "apps") {
            try? await state.env.engine.appsExplorer.listAll(serial: serial)
        }
        guard !Task.isCancelled else { return }
        apps = result ?? []
    }
}

/// Right pane: app info, permission count, and live permission toggles.
private struct AppDetailPane: View {
    @Environment(AppState.self) private var state
    let packageId: String

    private var derivedName: String {
        packageId.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? packageId
    }

    @State private var info: AppInfo?
    @State private var permissions: [PermissionEntry]?
    @State private var showPermissions = false
    @State private var mutating = false
    @State private var pullingApk = false

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
                        Text("Reading app info…").foregroundStyle(.secondary)
                    }
                }
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
                                .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(mutating)
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading permissions…").foregroundStyle(.secondary)
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
            }
        }
        .formStyle(.grouped)
        .task(id: "\(packageId)|\(state.targetSerials.first ?? "")") {
            await load()
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
        if let cached = AppIconCache.shared.image(for: packageId) {
            image = cached
            return
        }
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
