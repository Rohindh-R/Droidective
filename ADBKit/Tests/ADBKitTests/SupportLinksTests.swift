import Foundation
import Testing
@testable import ADBKit

@Suite struct SupportLinksTests {
    private let sample = DiagnosticsReport(
        appVersion: "2.0.0", appBuild: "1", macOSVersion: "14.5",
        architecture: "arm64", deviceSummary: "Pixel 7 · Android 14"
    )

    @Test func markdownFooterIncludesEnvironment() {
        let footer = sample.markdownFooter
        #expect(footer.contains("Droidective: 2.0.0 (1)"))
        #expect(footer.contains("macOS: 14.5"))
        #expect(footer.contains("arm64"))
        #expect(footer.contains("Device: Pixel 7 · Android 14"))
    }

    @Test func markdownFooterOmitsDeviceWhenAbsent() {
        let report = DiagnosticsReport(appVersion: "1", appBuild: "1", macOSVersion: "14", architecture: "arm64")
        #expect(!report.markdownFooter.contains("Device:"))
    }

    @Test func bugReportURLTargetsNewIssueWithDiagnostics() throws {
        let url = SupportLinks.bugReportURL(diagnostics: sample)
        #expect(url.absoluteString.hasPrefix("https://github.com/Rohindh-R/Droidective/issues/new"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        #expect(items.contains { $0.name == "labels" && $0.value == "bug" })
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("2.0.0 (1)"))
        #expect(body.contains("Steps to reproduce"))
    }

    @Test func featureRequestURLIsLabeledEnhancement() throws {
        let url = SupportLinks.featureRequestURL()
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        #expect(items.contains { $0.name == "labels" && $0.value == "enhancement" })
    }

    @Test func linksAreHTTPSGitHub() {
        #expect(SupportLinks.repoURL.scheme == "https")
        #expect(SupportLinks.repoURL.host == "github.com")
        #expect(SupportLinks.releasesURL.absoluteString.hasSuffix("/releases"))
    }
}
