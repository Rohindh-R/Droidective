import ADBKit
import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            ToolsSettingsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
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
    @AppStorage("showFrequent") private var showFrequent = true
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
                Toggle("Show Frequent section", isOn: $showFrequent)
                Text("Your most-run features float to the top of the list.")
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

struct ToolsSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            toolRow(name: "adb", status: state.adbStatus, tool: .adb)
            toolRow(name: "scrcpy", status: state.scrcpyStatus, tool: .scrcpy)
            Button("Re-detect tools") {
                Task {
                    await state.env.locator.clearCache()
                    await state.refreshToolStatus()
                }
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshToolStatus() }
    }

    @ViewBuilder
    private func toolRow(name: String, status: ToolStatus?, tool: Tool) -> some View {
        LabeledContent(name) {
            if let status {
                if status.installed {
                    VStack(alignment: .trailing) {
                        Label(status.version ?? "installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let path = status.path {
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button(state.installingTool == tool ? "Installing…" : "Install via Homebrew") {
                        state.installTool(tool)
                    }
                    .disabled(state.installingTool != nil)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
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
