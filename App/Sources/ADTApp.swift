import ADBKit
import SwiftUI

/// Routes APKs opened from Finder (double-click / "Open With") into the install
/// inbox, which surfaces the device picker once the UI is ready.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by RootView once the UI is up, so quit can tear down a kept-alive
    /// Reactotron session (server socket + adb reverse tunnels).
    weak var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        guard !apks.isEmpty else { return }
        InstallInbox.shared.receive(apks)
    }

    /// If the Reactotron server is still running (the user kept it alive), stop
    /// it before quitting so we don't orphan the listener or the reverse tunnel.
    /// Defers termination until the async teardown finishes (bounded in
    /// `stopForQuit`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = appState?.reactotronSession,
              MainActor.assumeIsolated({ session.isRunning }) else {
            return .terminateNow
        }
        Task { @MainActor in
            await session.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ADTApp: App {
    @State private var appState: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        // HotkeyManager.install is deferred to RootView.onAppear — Carbon
        // hot-key registration needs a running event loop, which App.init
        // predates.
        _appState = State(initialValue: AppState(env: AppEnvironment()))
        // Count this launch so the first-run privacy disclosure can be deferred
        // (gated in RootView). Telemetry is anonymous and on by default; start
        // it as early as possible.
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "launchCount") + 1, forKey: "launchCount")
        Telemetry.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
                // Force the brand accent on standard controls (prominent
                // buttons, switches, sliders) so they stay green regardless of
                // the Mac's system accent color, which otherwise overrides the
                // AccentColor asset.
                .tint(.brandAccent)
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

        Settings {
            SettingsView()
                .environment(appState)
                .tint(.brandAccent)
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
            state.activateMainWindow()
            state.selectedFeatureID = "scrcpy"
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
