import Foundation

/// Raw output of a finished (or killed) child process.
public struct ProcessOutput: Sendable {
    public var stdout: Data
    public var stderr: Data
    /// nil when the process was killed (timeout) or never launched.
    public var exitCode: Int32?
    public var timedOut: Bool

    public init(stdout: Data, stderr: Data, exitCode: Int32?, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Seam between ADBKit and the OS so every service is testable without
/// spawning real processes.
public protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: Duration,
        maxOutputBytes: Int
    ) async -> ProcessOutput
}

extension ProcessRunning {
    public func run(executable: String, arguments: [String], timeout: Duration = .seconds(30)) async -> ProcessOutput {
        await run(executable: executable, arguments: arguments, timeout: timeout, maxOutputBytes: 10 * 1024 * 1024)
    }
}
