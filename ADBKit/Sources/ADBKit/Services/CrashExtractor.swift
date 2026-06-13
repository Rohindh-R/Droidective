import Foundation

public enum CrashFormat: String, Sendable, CaseIterable {
    case plain
    case slack
    case jira

    public var label: String {
        switch self {
        case .plain: return "Plain"
        case .slack: return "Slack"
        case .jira: return "Jira"
        }
    }
}

/// Crash extraction: pulls the most recent crash from the crash buffer
/// (falling back to FATAL/AndroidRuntime/ReactNativeJS lines in the main
/// buffer) and formats it for pasting into Slack, Jira, or plain text.
public struct CrashExtractor: Sendable {
    public static let crashPattern = "FATAL EXCEPTION|AndroidRuntime|ReactNativeJS|FATAL SIGNAL"

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public static func extractLastCrash(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = -1
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            if lines[i].range(of: crashPattern, options: .regularExpression) != nil {
                index = i
                break
            }
        }
        guard index >= 0 else { return "" }
        let start = max(0, index - 2)
        let end = min(lines.count, index + 80)
        return lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func format(_ block: String, as format: CrashFormat) -> String {
        switch format {
        case .slack: return "```\n\(block)\n```"
        case .jira: return "{code}\n\(block)\n{code}"
        case .plain: return block
        }
    }

    /// Last crash from the device, formatted — nil when none found.
    public func lastCrash(serial: String, format: CrashFormat) async throws(AdbError) -> String? {
        let crashBuffer = try await client.run(on: serial, ["logcat", "-d", "-b", "crash", "-t", "300"])
        var block = crashBuffer.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if block.isEmpty {
            let mainBuffer = try await client.run(on: serial, ["logcat", "-d", "-b", "main", "-t", "1000"])
            block = Self.extractLastCrash(mainBuffer.stdout)
        }

        guard !block.isEmpty else { return nil }
        return Self.format(block, as: format)
    }
}
