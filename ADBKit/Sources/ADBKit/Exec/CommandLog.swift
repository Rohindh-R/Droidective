import Foundation

public struct CommandLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let command: String
    public let exitCode: Int32?
    public let duration: Duration
    public let stdout: String
    public let stderr: String
    /// The feature that triggered this command, when known — drives the
    /// per-feature command log. nil for commands run outside a feature scope.
    public let featureID: String?

    public init(
        id: UUID,
        timestamp: Date,
        command: String,
        exitCode: Int32?,
        duration: Duration,
        stdout: String,
        stderr: String,
        featureID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.exitCode = exitCode
        self.duration = duration
        self.stdout = stdout
        self.stderr = stderr
        self.featureID = featureID
    }
}

/// Recent adb invocations, surfaced in the in-app Command Log.
///
/// Only commands run inside a `CommandLog.$isUserInitiated.withValue(true)`
/// scope are recorded — so the log shows the user's actions, not background
/// polling (device list, override reconciliation, logcat pid lookups).
public actor CommandLog {
    @TaskLocal public static var isUserInitiated = false
    /// The feature id that the in-flight user action belongs to, so recorded
    /// commands can be attributed to a feature. Set via `userInitiated(feature:)`.
    @TaskLocal public static var currentFeatureID: String?

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
                stderr: String(stderr.prefix(CommandLog.maxCapture)),
                featureID: CommandLog.currentFeatureID
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

    /// Most-recent-first snapshot of the commands one feature ran.
    public func snapshot(featureID: String) -> [CommandLogEntry] {
        entries.reversed().filter { $0.featureID == featureID }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Clear only the commands recorded for one feature.
    public func clear(featureID: String) {
        entries.removeAll { $0.featureID == featureID }
    }
}

extension CommandLog {
    /// Run `body` as a user-initiated action attributed to `feature`, so the
    /// adb commands it triggers are recorded and tagged for the per-feature
    /// command log. Wraps the `isUserInitiated` / `currentFeatureID` task-locals.
    public static func userInitiated<T>(
        feature: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await CommandLog.$isUserInitiated.withValue(true) {
            try await CommandLog.$currentFeatureID.withValue(feature, operation: body)
        }
    }
}
