import Foundation

public enum Tool: String, Sendable, CaseIterable {
    case adb
    case scrcpy
    case brew
    case ffmpeg
    case emulator
}

public enum AdbError: Error, LocalizedError, Sendable {
    case adbNotFound

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "adb not found. Install Android platform-tools to continue."
        }
    }
}

/// Resolves absolute paths to external CLI tools (adb, scrcpy, brew, ffmpeg).
///
/// A GUI app launched from Finder inherits a minimal PATH that usually
/// excludes Homebrew and the Android SDK, so we never call a bare `adb`. We
/// probe well-known install locations and, as a fallback, ask the user's
/// login shell (which loads their full PATH) to resolve it. Results are
/// cached until `clearCache()` (e.g. after a tool install).
public actor ToolLocator {
    private var cache: [Tool: String?] = [:]
    private let runner: any ProcessRunning
    private let environment: [String: String]
    private let fileManager = FileManager.default

    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.environment = environment
    }

    public func resolve(_ tool: Tool) async -> String? {
        if let cached = cache[tool] { return cached }

        var resolved: String? = nil
        for candidate in candidatePaths(for: tool) where fileManager.isExecutableFile(atPath: candidate) {
            resolved = candidate
            break
        }
        if resolved == nil {
            resolved = await resolveViaLoginShell(tool)
        }
        // Negative results are cached too — Settings → Tools → "Re-detect"
        // and the brew-install flow call clearCache() to heal.
        cache[tool] = resolved
        return resolved
    }

    public func clearCache() {
        cache.removeAll()
    }

    /// Pre-populate the cache with a known path (tests, or a user-pinned
    /// tool location).
    public func seed(_ tool: Tool, path: String?) {
        cache[tool] = path
    }

    /// Resolve adb or throw a typed error the UI maps to an install prompt.
    public func adbPath() async throws(AdbError) -> String {
        guard let path = await resolve(.adb) else { throw .adbNotFound }
        return path
    }

    private func candidatePaths(for tool: Tool) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let brewPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]
        let sdkRoots = [
            environment["ANDROID_HOME"],
            environment["ANDROID_SDK_ROOT"],
            "\(home)/Library/Android/sdk",
        ].compactMap(\.self)

        switch tool {
        case .adb:
            return sdkRoots.map { "\($0)/platform-tools/adb" }
                + brewPrefixes.map { "\($0)/adb" }
        case .emulator:
            // The emulator launcher only ships with the SDK, not Homebrew.
            return sdkRoots.map { "\($0)/emulator/emulator" }
        case .scrcpy, .brew, .ffmpeg:
            return brewPrefixes.map { "\($0)/\(tool.rawValue)" }
        }
    }

    private func resolveViaLoginShell(_ tool: Tool) async -> String? {
        let output = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v \(tool.rawValue)"],
            timeout: .seconds(8),
            maxOutputBytes: 1024 * 1024
        )
        guard output.exitCode == 0 else { return nil }
        let resolved = output.stdoutText
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let resolved, fileManager.isExecutableFile(atPath: resolved) else { return nil }
        return resolved
    }
}
