import ADBKit
import SwiftUI

@main
struct ADTApp: App {
    @State private var appState: AppState

    init() {
        let state = AppState(env: AppEnvironment())
        _appState = State(initialValue: state)
        HotkeyManager.install(state: state)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.automatic)
        .commands {
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

        MenuBarExtra("Droidective", systemImage: "iphone.gen3") {
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

        ForEach(menuFeatures) { feature in
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

    /// Favorites first, falling back to the enabled instant actions.
    private var menuFeatures: [FeatureDef] {
        let favorites = state.layout.favorites.compactMap { FeatureRegistry.byID[$0] }
        if !favorites.isEmpty { return favorites }
        return state.enabledFeatures.filter {
            $0.kind == .instantAction && $0.id != "screenshot" && $0.id != "scrcpy"
        }
    }
}
