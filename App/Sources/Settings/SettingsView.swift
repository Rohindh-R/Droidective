import ADBKit
import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            DoctorSettingsView()
                .tabItem { Label("Doctor", systemImage: "stethoscope") }
            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .frame(width: 480)
        // Esc closes the Settings window. A zero-opacity button carrying the
        // Cancel (Esc) key equivalent fires regardless of which control holds
        // focus — more reliable here than .onExitCommand.
        .background {
            Button("") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// Applies the stored theme. Safe only once NSApplication exists — call it
/// from view lifecycle (RootView/Settings onAppear), never from App.init().
@MainActor
func applyStoredTheme() {
    switch UserDefaults.standard.string(forKey: "theme") {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    // "auto" — and the default when unset, so new users follow the system.
    default: NSApp.appearance = nil
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage("theme") private var theme = "auto"
    @AppStorage("groupSidebar") private var groupSidebar = true
    @AppStorage("showFeatureNotes") private var showFeatureNotes = false
    @AppStorage(ScreenCaptureService.captureFolderDefaultsKey) private var captureFolderPath = ""
    @AppStorage("showMenuBarExtra") private var showMenuBar = true
    @State private var showCommandLog = false
    @State private var openAtLoginOn = false

    private var captureFolderDisplay: String {
        captureFolderPath.isEmpty
            ? "~/Downloads/Droidective (default)"
            : (captureFolderPath as NSString).abbreviatingWithTildeInPath
    }

    /// True when the login item is registered (enabled, or pending the user's
    /// approval in System Settings).
    private func loginItemRegistered() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Registers/unregisters the app as a macOS login item. The toggle is backed
    /// by `openAtLoginOn` (the user's intent) rather than a live `status` read —
    /// `register`/`unregister` don't update `status` synchronously, so reading it
    /// each render snapped the toggle back to its old value.
    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { openAtLoginOn },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                        if SMAppService.mainApp.status == .requiresApproval {
                            state.showToast(Toast(
                                message: "Added — approve Droidective in System Settings ▸ General ▸ Login Items.",
                                ok: true
                            ))
                        }
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    openAtLoginOn = enabled
                } catch {
                    state.showToast(Toast(message: "Couldn't update Open at Login: \(error.localizedDescription)", ok: false))
                    openAtLoginOn = loginItemRegistered()
                }
            }
        )
    }

    private var roleBinding: Binding<UserRole?> {
        Binding(get: { state.selectedRole }, set: { state.chooseRole($0) })
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("Auto").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { applyStoredTheme() }

                Toggle("Show how-it-works notes", isOn: $showFeatureNotes)
                Text("The info text beneath each feature, above the command bar.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }

            Section("Sidebar") {
                Toggle("Group features by category", isOn: $groupSidebar)
                Text("Turn off to drag features into your own order.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }

            Section("Role") {
                Picker("Role", selection: roleBinding) {
                    Text("All features").tag(Optional<UserRole>.none)
                    ForEach(UserRole.allCases) { role in
                        Text(role.label).tag(Optional(role))
                    }
                }
                Text("Curates which features start visible — switching re-curates your set. Nothing is deleted; add any feature back from Home or the catalog.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
                Button("Open the role picker…") {
                    state.activateMainWindow()
                    state.presentRolePicker = true
                }
            }

            Section("Startup") {
                Toggle("Open at login", isOn: openAtLogin)
            }

            #if !APPSTORE
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { SparkleUpdater.shared.automaticallyChecksForUpdates },
                    set: { SparkleUpdater.shared.automaticallyChecksForUpdates = $0 }
                ))
                Text("Updates are delivered via Sparkle from GitHub Releases.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
            #endif

            Section("Menu bar") {
                Toggle("Show menu bar icon", isOn: $showMenuBar)
                if showMenuBar {
                    DisclosureGroup("Items shown in the menu") {
                        Text("When none are selected, your pinned features (or enabled instant actions) are shown. Screenshot and Mirror Screen always appear.")
                            .font(.footnote)
                            .foregroundStyle(.textMuted)
                            .padding(.vertical, 6)
                        ForEach(state.enabledFeatures) { feature in
                            Toggle(feature.title, isOn: Binding(
                                get: { state.isInMenuBar(feature.id) },
                                set: { state.setMenuBarItem(feature.id, included: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Privacy") {
                Toggle("Send anonymous crash reports", isOn: Binding(
                    get: { Telemetry.shared.crashReportingEnabled },
                    set: { Telemetry.shared.setCrashReporting($0) }
                ))
                Toggle("Share anonymous usage analytics", isOn: Binding(
                    get: { Telemetry.shared.analyticsEnabled },
                    set: { Telemetry.shared.setAnalytics($0) }
                ))
                Text("Crash reports help fix bugs; analytics shows which tools get used. Both are anonymous — no device data, file paths, or command contents are ever sent.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }

            Section("Data & Storage") {
                LabeledContent("Captures & pulls") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(captureFolderDisplay)
                            .font(.callout)
                            .foregroundStyle(.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Button("Change…") {
                                if let url = state.askSaveFolder(prompt: "Choose folder") {
                                    captureFolderPath = url.path
                                }
                            }
                            if !captureFolderPath.isEmpty {
                                Button("Reset") { captureFolderPath = "" }
                            }
                            Button("Open in Finder") {
                                if let dir = try? ScreenCaptureService.ensureCaptureDir() {
                                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                                }
                            }
                        }
                    }
                }
                LabeledContent("Command log") {
                    HStack {
                        Button("View…") { showCommandLog = true }
                        Button("Clear") { Task { await state.env.commandLog.clear() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLoginOn = loginItemRegistered() }
        .sheet(isPresented: $showCommandLog) {
            CommandLogView()
        }
    }
}

/// Setup Doctor: verifies the external toolchain (adb / emulator / Homebrew),
/// shows each tool's version and path, and offers a Homebrew install for the
/// brew-installable ones. scrcpy and ffmpeg aren't listed — the app bundles them.
struct DoctorSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var report: [Tool: ToolStatus] = [:]
    @State private var detecting = false

    private struct Check {
        let tool: Tool
        let name: String
        let purpose: String
        /// false for tools we can't `brew install` (emulator ships with the
        /// SDK; brew installs itself).
        let brewInstallable: Bool
    }

    private static let checks: [Check] = [
        Check(tool: .adb, name: "adb", purpose: "Required — powers every device action", brewInstallable: true),
        Check(tool: .emulator, name: "emulator", purpose: "Launch & manage Android emulators", brewInstallable: false),
        Check(tool: .brew, name: "Homebrew", purpose: "Installs the tools above", brewInstallable: false),
    ]

    /// Missing tools that actually block features (Homebrew alone isn't one).
    private var blockingMissing: [Tool] {
        Self.checks
            .filter { $0.tool != .brew && report[$0.tool]?.installed == false }
            .map(\.tool)
    }

    var body: some View {
        Form {
            Section { summary }
            Section("Toolchain") {
                ForEach(Self.checks, id: \.tool) { check in
                    row(check)
                }
            }
            Section {
                Button {
                    Task { await redetect() }
                } label: {
                    Label(detecting ? "Checking…" : "Re-check setup", systemImage: "arrow.clockwise")
                }
                .disabled(detecting)
            }
        }
        .formStyle(.grouped)
        .task { await redetect() }
        .onChange(of: state.installingTool) { _, installing in
            // A brew install finished — refresh so the row flips to installed.
            if installing == nil { Task { await redetect() } }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if report.isEmpty {
            Label("Checking your setup…", systemImage: "stethoscope")
                .foregroundStyle(.textMuted)
        } else if blockingMissing.isEmpty {
            Label("All set — every required tool is installed.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.brandAccent)
        } else {
            let n = blockingMissing.count
            Label(
                "\(n) tool\(n == 1 ? "" : "s") missing — some features won't work until installed.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    /// One compact row: a status icon + the tool name, expandable to reveal
    /// version, path, and (when missing) the install action.
    @ViewBuilder
    private func row(_ check: Check) -> some View {
        let status = report[check.tool]
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(check.purpose)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                if let status {
                    if let version = status.version {
                        detail("Version", version)
                    }
                    if let path = status.path {
                        detail("Path", path)
                    }
                    if !status.installed {
                        if check.brewInstallable {
                            Button(state.installingTool == check.tool ? "Installing…" : "Install via Homebrew") {
                                state.installTool(check.tool)
                            }
                            .disabled(state.installingTool != nil)
                        } else {
                            Text(status.installHint)
                                .font(.callout)
                                .foregroundStyle(.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                statusIcon(status)
                Text(check.name)
                Spacer()
                if let status, !status.installed {
                    Text("not installed")
                        .font(.caption)
                        .foregroundStyle(.textMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolStatus?) -> some View {
        if let status {
            Image(systemName: status.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.installed ? Color.brandAccent : Color.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.textMuted)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func redetect() async {
        detecting = true
        await state.env.locator.clearCache()
        report = await state.env.engine.toolDetection.detectAll()
        // Keep the device-bar adb gate in sync with what the Doctor just found.
        await state.refreshToolStatus()
        detecting = false
    }
}

struct HotkeysSettingsView: View {
    @Environment(AppState.self) private var state

    /// Hidden (disabled) features that still carry a recorded shortcut. They're
    /// off the sidebar but their hotkey keeps firing, so they need a home here
    /// to stay unbindable.
    private var orphanedShortcuts: [FeatureDef] {
        let shown = Set(state.sidebarFeatures.map(\.id))
        return FeatureRegistry.all.filter {
            !shown.contains($0.id)
                && KeyboardShortcuts.getShortcut(for: HotkeyManager.featureName($0.id)) != nil
        }
    }

    var body: some View {
        Form {
            Section("Global") {
                KeyboardShortcuts.Recorder("Show Droidective", name: .globalLaunch)
            }
            // Mirrors the sidebar: enabled features in their sidebar order.
            Section("Features") {
                ForEach(state.sidebarFeatures) { feature in
                    KeyboardShortcuts.Recorder(feature.title, name: HotkeyManager.featureName(feature.id))
                }
            }
            let orphans = orphanedShortcuts
            if !orphans.isEmpty {
                Section("Hidden features with shortcuts") {
                    ForEach(orphans) { feature in
                        KeyboardShortcuts.Recorder(feature.title, name: HotkeyManager.featureName(feature.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}
