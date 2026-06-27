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

    /// Cap the logcat dump we pull. The crash/main buffers can hold very large
    /// lines (RN apps log big payloads), and the default 10 MB ceiling is far
    /// more than the UI can render; 512 KB is plenty to find the latest crash.
    static let maxLogcatBytes = 512 * 1024

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public static func extractLastCrash(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
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

    /// Keep the rendered crash small without dropping its diagnostic header. A
    /// fatal log line can be huge (RN payload logging) and the crash buffer
    /// isn't otherwise trimmed, so the latest crash can balloon into a
    /// multi-megabyte string that freezes the UI when shown as a selectable
    /// Text. Android traces lead with the most useful lines (FATAL EXCEPTION,
    /// the exception type and message) and trail with framework frames, while
    /// the crash buffer itself is chronological (newest last). Keep both ends —
    /// the head so the exception is never silently lost, the tail so the newest
    /// crash survives — and elide the middle, under a character ceiling.
    static func boundedBlock(_ block: String, maxLines: Int = 200, maxChars: Int = 64 * 1024) -> String {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        var result = block
        if lines.count > maxLines {
            let (head, tail) = headTailSplit(count: lines.count, keep: maxLines)
            let elided = lines.count - head - tail
            result = (lines.prefix(head) + ["… \(elided) lines elided …"] + lines.suffix(tail))
                .joined(separator: "\n")
        }
        guard result.count > maxChars else { return result }
        let chars = Array(result)
        let (head, tail) = headTailSplit(count: chars.count, keep: maxChars)
        let elided = chars.count - head - tail
        return String(chars.prefix(head)) + "\n… \(elided) characters elided …\n" + String(chars.suffix(tail))
    }

    /// Head/tail counts for keeping the first ~2/3 and last ~1/3 of `count`
    /// items within `keep`, reserving one slot for the elision marker.
    private static func headTailSplit(count: Int, keep: Int) -> (head: Int, tail: Int) {
        let budget = max(keep - 1, 0)
        let head = budget * 2 / 3
        return (head, budget - head)
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
        let crashBuffer = try await client.run(
            on: serial, ["logcat", "-d", "-b", "crash", "-t", "300"], maxOutputBytes: Self.maxLogcatBytes
        )
        var block = crashBuffer.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if block.isEmpty {
            let mainBuffer = try await client.run(
                on: serial, ["logcat", "-d", "-b", "main", "-t", "1000"], maxOutputBytes: Self.maxLogcatBytes
            )
            block = Self.extractLastCrash(mainBuffer.stdout)
        }

        block = Self.boundedBlock(block)
        guard !block.isEmpty else { return nil }
        return Self.format(block, as: format)
    }
}
