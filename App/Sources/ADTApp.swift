import ADBKit
import SwiftUI

@main
struct ADTApp: App {
    @State private var appState: AppState
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        // HotkeyManager.install is deferred to RootView.onAppear — Carbon
        // hot-key registration needs a running event loop, which App.init
        // predates.
        _appState = State(initialValue: AppState(env: AppEnvironment()))
        // Start crash reporting as early as possible; analytics only if opted in.
        Telemetry.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.automatic)
        .commands {
            ScreenshotEditCommandsMenu()

            CommandGroup(replacing: .appInfo) {
                Button("About Droidective") {
                    appState.activateMainWindow()
                    appState.selectedFeatureID = "about"
                }
                #if !APPSTORE
                CheckForUpdatesCommand(updater: SparkleUpdater.shared)
                #endif
            }

            CommandGroup(replacing: .help) {
                Button("Report an Issue…") { appState.reportBug() }
                Button("Request a Feature…") { appState.requestFeature() }
                Divider()
                Button("Droidective on GitHub") { appState.openRepository() }
                Button("Release Notes") { appState.openReleases() }
            }

            CommandGroup(after: .textEditing) {
                Button("Find Feature") {
                    appState.openPalette?()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Manage Features") {
                    appState.activateMainWindow()
                    appState.selectedFeatureID = "catalog"
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    appState.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(appState.commandBarExpanded ? "Minimize Command Bar" : "Expand Command Bar") {
                    appState.commandBarExpanded.toggle()
                }
                .keyboardShortcut("j", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Increase Font Size") {
                    appState.increaseFontSize()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Font Size") {
                    appState.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    appState.resetFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Window("Search", id: "palette") {
            PaletteWindowView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(appState)
        }

        MenuBarExtra("Droidective", systemImage: "iphone.gen3", isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(appState)
        }
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let device = state.selectedDevice {
            Text(device.label)
        } else {
            Text("No device")
        }
        Divider()

        // Always-on quick actions — no window needed.
        Button("Screenshot") {
            runByID("screenshot")
        }
        Button("Mirror Screen") {
            runByID("scrcpy")
        }
        Divider()

        ForEach(state.menuBarFeatures) { feature in
            Button(feature.title) {
                if feature.kind == .instantAction {
                    Task { await state.run(feature: feature, params: [:]) }
                } else {
                    state.activateMainWindow()
                    state.selectedFeatureID = feature.id
                }
            }
        }
        Divider()
        Button("Open Droidective") {
            state.activateMainWindow()
        }
        Button("Quit Droidective") {
            NSApp.terminate(nil)
        }
    }

    private func runByID(_ id: String) {
        guard let feature = FeatureRegistry.byID[id] else { return }
        Task { await state.run(feature: feature, params: [:]) }
    }
}
