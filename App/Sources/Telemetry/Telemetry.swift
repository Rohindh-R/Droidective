import Foundation
import PostHog
import Sentry

/// Crash reporting (Sentry) and opt-in product analytics (PostHog). Lives in the
/// App layer so ADBKit stays dependency-free and `swift test` stays clean.
///
/// Everything is anonymous: no device serials, package ids, file paths, IPs, or
/// command contents are ever sent — only which tool was used. Crash reporting is
/// on by default (disclosed on first launch, opt-out in Settings → Privacy);
/// product analytics is opt-in.
@MainActor
final class Telemetry {
    static let shared = Telemetry()
    private init() {}

    static let crashReportingKey = "crashReportingEnabled"
    static let analyticsKey = "analyticsEnabled"

    /// Defaults ON. Disclosed at first launch; opt-out in Settings → Privacy.
    var crashReportingEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.crashReportingKey) as? Bool ?? true
    }

    /// Defaults OFF — opt-in only.
    var analyticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.analyticsKey)
    }

    private var sentryRunning = false
    private var postHogReady = false

    /// Apply the stored consent. Call once at launch.
    func start() {
        if crashReportingEnabled { startSentry() }
        if analyticsEnabled { startAnalytics() }
    }

    func setCrashReporting(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.crashReportingKey)
        if enabled { startSentry() } else { stopSentry() }
    }

    func setAnalytics(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.analyticsKey)
        if enabled { startAnalytics() } else { stopAnalytics() }
    }

    /// Record an anonymous product-analytics event. No-op unless opted in.
    func track(_ event: String, _ properties: [String: Any] = [:]) {
        guard analyticsEnabled, postHogReady else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    // MARK: - Sentry (crashes + performance)

    private func startSentry() {
        guard !sentryRunning, TelemetryConfig.sentryConfigured else { return }
        SentrySDK.start { options in
            options.dsn = TelemetryConfig.sentryDSN
            options.sendDefaultPii = false
            options.tracesSampleRate = 0.2
            options.enableUncaughtNSExceptionReporting = true
            #if DEBUG
            options.debug = true  // verbose Sentry logs in dev builds only
            #endif
        }
        sentryRunning = true
    }

    private func stopSentry() {
        guard sentryRunning else { return }
        SentrySDK.close()
        sentryRunning = false
    }

    // MARK: - PostHog (opt-in analytics)

    private func startAnalytics() {
        guard TelemetryConfig.analyticsConfigured else { return }
        if !postHogReady {
            let config = PostHogConfig(projectToken: TelemetryConfig.postHogKey, host: TelemetryConfig.postHogHost)
            config.personProfiles = .never               // fully anonymous — never identify
            config.errorTrackingConfig.autoCapture = false  // Sentry owns crash reporting
            #if DEBUG
            config.debug = true  // verbose PostHog logs in dev builds only
            #endif
            PostHogSDK.shared.setup(config)
            postHogReady = true
        }
        PostHogSDK.shared.optIn()
    }

    private func stopAnalytics() {
        guard postHogReady else { return }
        PostHogSDK.shared.optOut()
    }
}
