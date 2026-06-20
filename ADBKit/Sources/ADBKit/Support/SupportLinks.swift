import Foundation

/// Static support metadata and GitHub deep links for the About & Feedback
/// surface. Pure value logic — no UI, no `Bundle` access — so it stays unit
/// testable inside ADBKit. The app layer supplies the runtime
/// `DiagnosticsReport` values that can't be known from here.
public enum SupportLinks {
    public static let repoOwner = "Rohindh-R"
    public static let repoName = "Droidective"
    public static let authorName = "Rohindh R"

    public static let repoURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)")!
    public static let releasesURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases")!
    public static let authorURL = URL(string: "https://github.com/\(repoOwner)")!

    /// Pre-filled new-issue link for a bug, with a diagnostics footer so reports
    /// arrive with the environment already attached.
    public static func bugReportURL(diagnostics: DiagnosticsReport) -> URL {
        newIssueURL(
            title: "[Bug] ",
            labels: "bug",
            body: """
            **What happened?**


            **Steps to reproduce**
            1.
            2.

            **Expected behaviour**


            \(diagnostics.markdownFooter)
            """
        )
    }

    /// Pre-filled new-issue link for a feature request.
    public static func featureRequestURL() -> URL {
        newIssueURL(
            title: "[Feature] ",
            labels: "enhancement",
            body: """
            **What would you like Droidective to do?**


            **Why is it useful?**

            """
        )
    }

    private static func newIssueURL(title: String, labels: String, body: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repoOwner)/\(repoName)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: labels),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? releasesURL
    }
}

/// A snapshot of the running environment, embedded in bug reports so a filed
/// issue already carries the app version, OS, and the connected device.
public struct DiagnosticsReport: Sendable, Equatable {
    public let appVersion: String
    public let appBuild: String
    public let macOSVersion: String
    public let architecture: String
    public let deviceSummary: String?

    public init(
        appVersion: String,
        appBuild: String,
        macOSVersion: String,
        architecture: String,
        deviceSummary: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.deviceSummary = deviceSummary
    }

    /// Markdown environment block appended to a new-issue body.
    public var markdownFooter: String {
        var lines = [
            "---",
            "- Droidective: \(appVersion) (\(appBuild))",
            "- macOS: \(macOSVersion)",
            "- Architecture: \(architecture)",
        ]
        if let deviceSummary, !deviceSummary.isEmpty {
            lines.append("- Device: \(deviceSummary)")
        }
        return lines.joined(separator: "\n")
    }
}
