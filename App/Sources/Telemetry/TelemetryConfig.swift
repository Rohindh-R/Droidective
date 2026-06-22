import Foundation

/// Telemetry endpoints. These are client-side write keys (designed to ship in
/// the app binary), but they're injected at build time from the `SENTRY_DSN` and
/// `POSTHOG_KEY` build settings into Info.plist (see project.yml / RELEASING.md)
/// rather than committed, so forks don't report to the upstream projects and the
/// values can be rotated without a code change. A build without the keys leaves
/// each value empty, which keeps that SDK from ever starting.
enum TelemetryConfig {
    /// Sentry DSN — Project Settings → Client Keys (DSN). Client-side write key.
    static let sentryDSN = infoValue("SentryDSN")

    /// PostHog project token (starts with `phc_`) and cloud host. Client-side key.
    static let postHogKey = infoValue("PostHogKey")
    static let postHogHost = "https://us.i.posthog.com"  // US project (verified)

    static var sentryConfigured: Bool { sentryDSN.hasPrefix("https://") }
    static var analyticsConfigured: Bool { postHogKey.hasPrefix("phc_") }

    private static func infoValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
