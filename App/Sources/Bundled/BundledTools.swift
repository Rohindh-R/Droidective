import ADBKit
import Foundation

/// Single source of truth for the third-party binaries shipped inside the app
/// bundle, so Droidective is self-contained (no `brew install scrcpy`/`ffmpeg`).
///
/// **Updating a bundled tool** (scalable on purpose): run
/// `scripts/update-bundled-tools.sh`, which downloads the pinned versions into
/// `App/Resources/`, then bump the version constants here if they changed. The
/// resources are forced into the app's resources build phase in `project.yml`,
/// signed by `scripts/package-dmg.sh`, and attributed in `THIRD_PARTY_NOTICES.md`.
/// Lives in the App layer because ADBKit is bundle-free; resolved paths are
/// passed into ADBKit services.
enum BundledTools {
    /// scrcpy-server payload version. MUST match the bundled `scrcpy-server`
    /// binary — `app_process` is launched with it and the server aborts on a
    /// version mismatch. Keep in lockstep with the binary in `App/Resources`.
    static let scrcpyVersion = "4.0"

    private static let scrcpyServerResource = "scrcpy-server"
    private static let ffmpegResource = "ffmpeg"

    /// The bundled scrcpy server (jar path + version), or nil if the resource is
    /// missing from the build.
    static func scrcpyServer() -> ScrcpyServerInfo? {
        guard let url = Bundle.main.url(forResource: scrcpyServerResource, withExtension: nil) else {
            return nil
        }
        return ScrcpyServerInfo(jarPath: url.path, version: scrcpyVersion)
    }

    /// Absolute path to the bundled ffmpeg executable, or nil if it's missing.
    static func ffmpegPath() -> String? {
        Bundle.main.url(forResource: ffmpegResource, withExtension: nil)?.path
    }
}
