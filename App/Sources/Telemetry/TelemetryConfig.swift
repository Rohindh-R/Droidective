import Foundation

/// Telemetry endpoints. These are client-side write keys (designed to ship in
/// the app binary). Leave a placeholder to keep that channel disabled — the
/// SDK is never started until a real value is present.
enum TelemetryConfig {
    /// Sentry DSN — Project Settings → Client Keys (DSN). Client-side write key.
    static let sentryDSN = "https://b1623c7ab30b0b7c0297cf880979b9b1@o4511598359609344.ingest.de.sentry.io/4511598365835344"

    /// PostHog project token (starts with `phc_`) and cloud host. Client-side key.
    static let postHogKey = "phc_pBw3mRbMGvFHTZV5ipCHo5WwQUkiwFpqVrBaq9jdkFkV"
    static let postHogHost = "https://us.i.posthog.com"  // US project (verified)

    static var sentryConfigured: Bool { sentryDSN.hasPrefix("https://") }
    static var analyticsConfigured: Bool { postHogKey.hasPrefix("phc_") }
}
