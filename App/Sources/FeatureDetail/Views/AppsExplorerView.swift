import ADBKit
import SwiftUI

/// Every installed app (user + system) with search across name, version,
/// and bundle id. Selecting one shows its info, permission count, and live
/// permission toggles.
struct AppsExplorerView: View {
    @Environment(AppState.self) private var state
    @State private var apps: [AppListing]?
    @State private var search = ""
    @State private var scope = Scope.all
    @State private var selectedPackage: String?

    enum Scope: String, CaseIterable {
        case all = "All"
        case user = "User"
        case system = "System"
    }

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
        let result = try? await state.env.engine.appsExplorer.listAll(serial: serial)
        guard !Task.isCancelled else { return }
        apps = result ?? []
    }
}

/// Right pane: app info, permission count, and live permission toggles.
private struct AppDetailPane: View {
    @Environment(AppState.self) private var state
    let packageId: String

    @State private var info: AppInfo?
    @State private var permissions: [PermissionEntry]?
    @State private var showPermissions = false
    @State private var mutating = false
    @State private var pullingApk = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Bundle") {
                    Text(packageId).textSelection(.enabled)
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
        async let infoResult = try? state.env.engine.inspection.getAppInfo(serial: serial, packageId: packageId)
        async let permissionsResult = try? state.env.engine.inspection.listPermissions(serial: serial, packageId: packageId)
        let (fetchedInfo, fetchedPermissions) = await (infoResult, permissionsResult)
        guard !Task.isCancelled else { return }
        info = fetchedInfo ?? .notInstalled
        permissions = fetchedPermissions ?? []
    }

    private func pullApk() {
        guard let serial = state.targetSerials.first else { return }
        guard let dest = state.askSaveLocation(suggestedName: "\(packageId).apk") else { return }
        pullingApk = true
        Task {
            await CommandLog.$isUserInitiated.withValue(true) {
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
            await CommandLog.$isUserInitiated.withValue(true) {
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
