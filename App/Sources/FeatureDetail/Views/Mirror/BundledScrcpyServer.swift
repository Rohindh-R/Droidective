import ADBKit
import Foundation

/// The `scrcpy-server` bundled in the app, so the mirror is self-contained and
/// doesn't need `brew install scrcpy`. Lives in the App layer because ADBKit is
/// UI/bundle-free; the resolved info is passed into the transport config.
enum BundledScrcpyServer {
    /// MUST match the bundled `scrcpy-server` payload — the server aborts if the
    /// version passed to `app_process` differs from its own. Bump this whenever
    /// `App/Resources/scrcpy-server` is updated.
    static let version = "4.0"

    static func info() -> ScrcpyServerInfo? {
        guard let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else {
            return nil
        }
        return ScrcpyServerInfo(jarPath: url.path, version: version)
    }
}
