import Foundation

public struct CommandLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let command: String
    public let exitCode: Int32?
    public let duration: Duration
    public let stdout: String
    public let stderr: String
}

/// Recent adb invocations, surfaced in the in-app Command Log.
///
/// Only commands run inside a `CommandLog.$isUserInitiated.withValue(true)`
/// scope are recorded — so the log shows the user's actions, not background
/// polling (device list, override reconciliation, logcat pid lookups).
public actor CommandLog {
    @TaskLocal public static var isUserInitiated = false

    public static let maxEntries = 200
    public static let maxCapture = 8000

    private var entries: [CommandLogEntry] = []

    public init() {}

    public func record(command: String, exitCode: Int32?, duration: Duration, stdout: String, stderr: String) {
        guard CommandLog.isUserInitiated else { return }
        entries.append(
            CommandLogEntry(
                id: UUID(),
                timestamp: Date(),
                command: command,
                exitCode: exitCode,
                duration: duration,
                stdout: String(stdout.prefix(CommandLog.maxCapture)),
                stderr: String(stderr.prefix(CommandLog.maxCapture))
            )
        )
        if entries.count > CommandLog.maxEntries {
            entries.removeFirst(entries.count - CommandLog.maxEntries)
        }
    }

    /// Most-recent-first snapshot.
    public func snapshot() -> [CommandLogEntry] {
        entries.reversed()
    }

    public func clear() {
        entries.removeAll()
    }
}
