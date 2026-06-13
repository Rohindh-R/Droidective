import Foundation

/// Structured result of one adb invocation. Non-zero exits are data, not
/// errors — callers map stderr to a friendly message.
public struct AdbResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32?
    public var timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32?, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The generic adb exec wrapper every action depends on. Throws only
/// `AdbError.adbNotFound`; command failures come back as `AdbResult`.
public struct AdbClient: Sendable {
    public static let defaultTimeout: Duration = .seconds(30)
    public static let defaultMaxOutput = 10 * 1024 * 1024

    public let locator: ToolLocator
    public let log: CommandLog
    let runner: any ProcessRunning

    public init(locator: ToolLocator, runner: any ProcessRunning = SystemProcessRunner(), log: CommandLog = CommandLog()) {
        self.locator = locator
        self.runner = runner
        self.log = log
    }

    /// Run a global adb command (no device target).
    public func run(
        _ args: [String],
        timeout: Duration = AdbClient.defaultTimeout,
        maxOutputBytes: Int = AdbClient.defaultMaxOutput
    ) async throws(AdbError) -> AdbResult {
        let output = try await runRaw(args, timeout: timeout, maxOutputBytes: maxOutputBytes)
        var stderr = output.stderrText
        if stderr.isEmpty && output.exitCode != 0 {
            stderr = "adb command failed"
        }
        return AdbResult(
            stdout: output.stdoutText,
            stderr: stderr,
            exitCode: output.exitCode,
            timedOut: output.timedOut
        )
    }

    /// Run adb scoped to a single device via `-s <serial>`.
    public func run(
        on serial: String,
        _ args: [String],
        timeout: Duration = AdbClient.defaultTimeout,
        maxOutputBytes: Int = AdbClient.defaultMaxOutput
    ) async throws(AdbError) -> AdbResult {
        try await run(["-s", serial] + args, timeout: timeout, maxOutputBytes: maxOutputBytes)
    }

    /// Fan a command out across several devices, one result per serial.
    public func runOnAll(
        serials: [String],
        _ args: [String],
        timeout: Duration = AdbClient.defaultTimeout
    ) async throws(AdbError) -> [(serial: String, result: AdbResult)] {
        // Resolve once up front so a missing adb fails the whole fan-out.
        _ = try await locator.adbPath()
        return await withTaskGroup(of: (Int, String, AdbResult).self) { group in
            for (index, serial) in serials.enumerated() {
                group.addTask {
                    let result = (try? await run(on: serial, args, timeout: timeout))
                        ?? AdbResult(stdout: "", stderr: "adb not found", exitCode: nil, timedOut: false)
                    return (index, serial, result)
                }
            }
            var collected: [(Int, String, AdbResult)] = []
            for await item in group { collected.append(item) }
            collected.sort { $0.0 < $1.0 }
            return collected.map { (serial: $0.1, result: $0.2) }
        }
    }

    /// Run adb and return raw bytes — for binary streams like
    /// `exec-out screencap -p` where text decoding would corrupt the payload.
    public func runBinary(
        on serial: String,
        _ args: [String],
        timeout: Duration = AdbClient.defaultTimeout,
        maxOutputBytes: Int = 50 * 1024 * 1024
    ) async throws(AdbError) -> ProcessOutput {
        try await runRaw(["-s", serial] + args, timeout: timeout, maxOutputBytes: maxOutputBytes, binary: true)
    }

    private func runRaw(
        _ args: [String],
        timeout: Duration,
        maxOutputBytes: Int,
        binary: Bool = false
    ) async throws(AdbError) -> ProcessOutput {
        let adbPath = try await locator.adbPath()
        let clock = ContinuousClock()
        let started = clock.now
        let output = await runner.run(
            executable: adbPath,
            arguments: args,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
        await log.record(
            command: "adb \(args.joined(separator: " "))",
            exitCode: output.exitCode,
            duration: clock.now - started,
            stdout: binary ? "<binary, \(output.stdout.count) bytes>" : output.stdoutText,
            stderr: output.stderrText
        )
        return output
    }
}

/// Single-quote a value for the *device-side* shell. `adb shell` joins its
/// arguments with spaces and runs them through `sh` on the device, so any
/// user-supplied path/URL must be quoted to survive spaces and metacharacters.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Map common adb stderr to a short, human message.
public func friendlyAdbError(_ result: AdbResult, fallback: String) -> String {
    if result.timedOut { return "The command timed out." }
    let text = result.stderr.lowercased()
    if text.contains("no devices") || text.contains("device not found") {
        return "No device connected."
    }
    if text.contains("device offline") { return "Device is offline." }
    if text.contains("unauthorized") {
        return "Device is unauthorized — accept the USB debugging prompt."
    }
    if text.contains("more than one device") {
        return "Multiple devices — pick a target device."
    }
    let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
}
