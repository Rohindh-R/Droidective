import ADBKit
import AppKit
import SwiftUI

/// App chrome (like Home / Catalog, not a registry feature): app version,
/// links to star and view the repo, one-click bug reports / feature requests
/// pre-filled with diagnostics, release notes, and author info.
struct AboutView: View {
    @Environment(AppState.self) private var state

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                supportSection
                feedbackSection
                updatesSection
                authorSection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About & Feedback")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("Droidective")
                    .font(.largeTitle.bold())
                Text(versionLine)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("An Android & React Native debugging command palette, driven over adb.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sections

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Enjoying Droidective?")
            linkRow(
                icon: "star",
                title: "Star it on GitHub",
                detail: "A star helps other developers discover the project.",
                button: "★ Star"
            ) { state.openRepository() }
        }
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Feedback")
            linkRow(
                icon: "ladybug",
                title: "Report a bug",
                detail: "Opens a new GitHub issue pre-filled with your app version, macOS, and connected device.",
                button: "Report a Bug"
            ) { state.reportBug() }
            linkRow(
                icon: "lightbulb",
                title: "Request a feature",
                detail: "Have an idea? Open a feature request on GitHub.",
                button: "Request a Feature"
            ) { state.requestFeature() }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Updates")
            #if !APPSTORE
            linkRow(
                icon: "arrow.triangle.2.circlepath",
                title: "Check for updates",
                detail: "Droidective checks automatically — you can also check right now.",
                button: "Check Now"
            ) { SparkleUpdater.shared.checkForUpdates() }
            #endif
            linkRow(
                icon: "shippingbox",
                title: "Releases",
                detail: "Browse every version and its release notes on GitHub.",
                button: "View Releases"
            ) { state.openReleases() }
        }
    }

    private var authorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Author")
            linkRow(
                icon: "person.crop.circle",
                title: "Made by \(SupportLinks.authorName)",
                detail: "Built as a native macOS tool for Android & React Native debugging.",
                button: "GitHub"
            ) { state.openAuthor() }
        }
    }

    // MARK: - Building blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title2.bold())
    }

    private func linkRow(
        icon: String,
        title: String,
        detail: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
