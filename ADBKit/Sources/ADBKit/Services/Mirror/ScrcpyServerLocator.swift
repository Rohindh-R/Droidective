import Foundation

/// The device-side `scrcpy-server` payload plus the scrcpy version it must be
/// launched with (the server aborts on a version mismatch).
public struct ScrcpyServerInfo: Sendable, Equatable {
    public let jarPath: String
    public let version: String

    public init(jarPath: String, version: String) {
        self.jarPath = jarPath
        self.version = version
    }
}

/// Resolves `ScrcpyServerInfo`. The path/version parsing is pure and unit-tested;
/// `resolve` wires it to the real toolchain. For now the server is reused from
/// the installed scrcpy (Homebrew lays it beside the binary); bundling it in the
/// app is a later packaging step.
public enum ScrcpyServerLocator {
    /// Homebrew layout: `<prefix>/bin/scrcpy` → `<prefix>/share/scrcpy/scrcpy-server`.
    public static func jarPath(forBinary binaryPath: String) -> String {
        let binDir = (binaryPath as NSString).deletingLastPathComponent
        let prefix = (binDir as NSString).deletingLastPathComponent
        return prefix + "/share/scrcpy/scrcpy-server"
    }

    /// Parse the version token from scrcpy's banner: `scrcpy 4.0 <url>` → `4.0`.
    public static func parseVersion(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "scrcpy" { return String(parts[1]) }
        }
        return nil
    }

    /// Resolve the installed scrcpy's server jar and version via the locator and a
    /// `scrcpy --version` probe. Returns nil if scrcpy isn't installed.
    public static func resolve(
        locator: ToolLocator,
        runner: any ProcessRunning = SystemProcessRunner()
    ) async -> ScrcpyServerInfo? {
        guard let binaryPath = await locator.resolve(.scrcpy) else { return nil }
        let jar = jarPath(forBinary: binaryPath)
        let probe = await runner.run(
            executable: binaryPath, arguments: ["--version"], timeout: .seconds(8))
        guard let version = parseVersion(probe.stdoutText) else { return nil }
        return ScrcpyServerInfo(jarPath: jar, version: version)
    }
}
