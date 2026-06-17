import ADBKit
import AppKit
import KeyboardShortcuts
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
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "internaldrive") }
        }
        .frame(width: 480)
    }
}

/// Applies the stored theme. Safe only once NSApplication exists — call it
/// from view lifecycle (RootView/Settings onAppear), never from App.init().
@MainActor
func applyStoredTheme() {
    switch UserDefaults.standard.string(forKey: "theme") {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    default: NSApp.appearance = nil
    }
}

struct GeneralSettingsView: View {
    @AppStorage("theme") private var theme = "auto"
    @AppStorage("groupSidebar") private var groupSidebar = true
    @AppStorage("restoreLastFeature") private var restoreLastFeature = true

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
            }

            Section("Sidebar") {
                Toggle("Group features by category", isOn: $groupSidebar)
                Text("Turn off to drag features into your own order.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Reopen the last used feature", isOn: $restoreLastFeature)
            }
        }
        .formStyle(.grouped)
    }
}

/// Setup Doctor: verifies the external toolchain (adb / scrcpy / emulator /
/// ffmpeg / Homebrew), shows each tool's version and path, and offers a
/// Homebrew install for the brew-installable ones.
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
        Check(tool: .scrcpy, name: "scrcpy", purpose: "Mirror Screen", brewInstallable: true),
        Check(tool: .emulator, name: "emulator", purpose: "Launch & manage Android emulators", brewInstallable: false),
        Check(tool: .ffmpeg, name: "ffmpeg", purpose: "GIF export in Screen Record", brewInstallable: true),
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
                .foregroundStyle(.secondary)
        } else if blockingMissing.isEmpty {
            Label("All set — every required tool is installed.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
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
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolStatus?) -> some View {
        if let status {
            Image(systemName: status.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.installed ? Color.green : Color.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
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

    var body: some View {
        Form {
            Section("Global") {
                KeyboardShortcuts.Recorder("Show Droidective", name: .globalLaunch)
            }
            // Every feature, not just enabled ones — a recorded shortcut
            // keeps firing even after its feature is hidden from the
            // sidebar, so it must stay visible and unbindable here.
            Section("Features") {
                ForEach(FeatureRegistry.all) { feature in
                    KeyboardShortcuts.Recorder(feature.title, name: HotkeyManager.featureName(feature.id))
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}

struct DataSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var showCommandLog = false

    var body: some View {
        Form {
            LabeledContent("Data folder") {
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDir])
                }
            }
            LabeledContent("Captures folder") {
                Button("Open in Finder") {
                    if let dir = try? ScreenCaptureService.ensureCaptureDir() {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
            LabeledContent("Command log") {
                HStack {
                    Button("View…") {
                        showCommandLog = true
                    }
                    Button("Clear") {
                        Task { await state.env.commandLog.clear() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCommandLog) {
            CommandLogView()
        }
    }
}
