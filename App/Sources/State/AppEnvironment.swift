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
        locator = ToolLocator()
        commandLog = CommandLog()
        client = AdbClient(locator: locator, log: commandLog)
        monitor = DeviceMonitor(client: client)
        stores = AppStores()
        engine = FeatureEngine(client: client, locator: locator, monitor: monitor, overridesStore: stores.overrides)
    }
}
