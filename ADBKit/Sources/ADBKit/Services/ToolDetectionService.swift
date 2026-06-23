import Foundation

public struct ToolStatus: Sendable, Equatable {
    public let installed: Bool
    public let path: String?
    public let version: String?
    public let installHint: String
}

/// Detects whether adb / scrcpy are installed and offers a one-click
/// Homebrew install through the user's login shell.
public struct ToolDetectionService: Sendable {
    static let installHints: [Tool: String] = [
        .adb: "Install Android platform-tools — `brew install --cask android-platform-tools` (or Android Studio).",
        .scrcpy: "Install scrcpy to mirror the screen — `brew install scrcpy`.",
        .ffmpeg: "Install ffmpeg for video editing & export — `brew install ffmpeg`.",
        .emulator: "Bundled with the Android SDK — install it via Android Studio → SDK Manager.",
        .brew: "Install Homebrew from https://brew.sh, then re-check.",
    ]

    /// The flag each tool prints its version with.
    static let versionArgs: [Tool: [String]] = [
        .adb: ["version"],
        .scrcpy: ["--version"],
        .emulator: ["-version"],
        .ffmpeg: ["-version"],
        .brew: ["--version"],
    ]

    let locator: ToolLocator
    let runner: any ProcessRunning

    public init(locator: ToolLocator, runner: any ProcessRunning = SystemProcessRunner()) {
        self.locator = locator
        self.runner = runner
    }

    /// Detect adb — the only external tool the app gates on (scrcpy and ffmpeg
    /// are bundled). The Doctor uses `detectAll` for the full report.
    public func detectAdb() async -> ToolStatus {
        await detectOne(.adb, versionArgs: ["version"])
    }

    /// Detect every external tool the app can use, for the setup Doctor.
    public func detectAll() async -> [Tool: ToolStatus] {
        await withTaskGroup(of: (Tool, ToolStatus).self) { group in
            for tool in Tool.allCases {
                group.addTask {
                    (tool, await detectOne(tool, versionArgs: Self.versionArgs[tool] ?? ["--version"]))
                }
            }
            var report: [Tool: ToolStatus] = [:]
            for await (tool, status) in group {
                report[tool] = status
            }
            return report
        }
    }

    func detectOne(_ tool: Tool, versionArgs: [String]) async -> ToolStatus {
        let hint = Self.installHints[tool] ?? ""
        guard let path = await locator.resolve(tool) else {
            return ToolStatus(installed: false, path: nil, version: nil, installHint: hint)
        }
        let output = await runner.run(
            executable: path, arguments: versionArgs, timeout: .seconds(8), maxOutputBytes: 1024 * 1024
        )
        let text = output.stdoutText.isEmpty ? output.stderrText : output.stdoutText
        let version = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ToolStatus(installed: true, path: path, version: version, installHint: hint)
    }

    /// Install a tool via Homebrew. Slow (minutes) — callers should show
    /// progress and refresh detection afterwards.
    public func installViaBrew(_ tool: Tool) async -> FeatureResult {
        guard let brew = await locator.resolve(.brew) else {
            return FeatureResult(
                ok: false,
                message: "Homebrew isn't installed. Install it from https://brew.sh, then try again."
            )
        }
        let command = tool == .adb
            ? "\(brew) install --cask android-platform-tools"
            : "\(brew) install \(tool.rawValue)"
        let output = await runner.run(
            executable: "/bin/zsh", arguments: ["-lc", command],
            timeout: .seconds(300), maxOutputBytes: 10 * 1024 * 1024
        )
        if output.exitCode == 0 {
            await locator.clearCache()
            return FeatureResult(ok: true, message: "\(tool.rawValue) installed successfully.")
        }
        let reason = output.stderrText.split(whereSeparator: \.isNewline).last.map(String.init) ?? "brew failed"
        return FeatureResult(ok: false, message: "Couldn't install \(tool.rawValue): \(reason)")
    }
}
