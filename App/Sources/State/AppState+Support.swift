import ADBKit
import AppKit

/// About & Feedback actions. The app layer owns these because they read the
/// running app's `Bundle`/`ProcessInfo` and open URLs — values ADBKit's pure
/// `SupportLinks` can't know.
extension AppState {
    /// A diagnostics snapshot for bug reports: app version/build, macOS, arch,
    /// and the selected device when one is connected and ready.
    func currentDiagnostics() -> DiagnosticsReport {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsReport(
            appVersion: version,
            appBuild: build,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: Self.architecture,
            deviceSummary: selectedDeviceSummary
        )
    }

    private var selectedDeviceSummary: String? {
        guard let device = selectedDevice, device.isReady else { return nil }
        var parts = [device.label]
        if let version = deviceDetails[device.serial]?.androidVersion {
            parts.append("Android \(version)")
        }
        return parts.joined(separator: " · ")
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    func openSupportLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reportBug() { openSupportLink(SupportLinks.bugReportURL(diagnostics: currentDiagnostics())) }
    func requestFeature() { openSupportLink(SupportLinks.featureRequestURL()) }
    func openRepository() { openSupportLink(SupportLinks.repoURL) }
    func openReleases() { openSupportLink(SupportLinks.releasesURL) }
    func openAuthor() { openSupportLink(SupportLinks.authorURL) }
}
