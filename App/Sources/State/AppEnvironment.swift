import ADBKit
import Foundation

/// Composition root: builds the ADBKit actors and stores exactly once.
struct AppEnvironment: Sendable {
    let locator: ToolLocator
    let commandLog: CommandLog
    let client: AdbClient
    let monitor: DeviceMonitor
    let engine: FeatureEngine
    let stores: AppStores

    init() {
        locator = ToolLocator(bundledToolsDirectory: Self.bundledToolsDirectory)
        commandLog = CommandLog()
        client = AdbClient(locator: locator, log: commandLog)
        monitor = DeviceMonitor(client: client)
        stores = AppStores()
        engine = FeatureEngine(client: client, locator: locator, monitor: monitor, overridesStore: stores.overrides)
    }

    /// scrcpy/ffmpeg copies shipped inside the app bundle (injected at packaging
    /// time by scripts/bundle-tools.sh). Absent in dev builds, where the locator
    /// falls back to the developer's Homebrew/SDK installs.
    private static let bundledToolsDirectory = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers", isDirectory: true)
}
