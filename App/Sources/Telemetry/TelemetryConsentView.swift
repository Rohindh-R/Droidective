import SwiftUI

/// One-time privacy disclosure shown on first launch (after the welcome tour).
/// Crash reporting is on by default; analytics is opt-in. Both are toggleable
/// here and later in Settings → Privacy.
struct TelemetryConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("telemetryConsentAsked") private var consentAsked = false
    @State private var crashReports = true
    @State private var analytics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("Privacy & telemetry")
                    .font(.title2.bold())
            }

            Text("Droidective can send **anonymous** diagnostics to help improve it. No device serials, package names, file paths, IP addresses, or command contents are ever sent.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                Toggle(isOn: $crashReports) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anonymous crash reports")
                        Text("Helps fix the bugs you hit. Recommended.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                Divider()
                Toggle(isOn: $analytics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anonymous usage analytics")
                        Text("Which tools get used, so the useful ones improve.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            Text("You can change this anytime in Settings → Privacy.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(26)
        .frame(width: 460)
        .onAppear { crashReports = Telemetry.shared.crashReportingEnabled }
    }

    private func finish() {
        Telemetry.shared.setCrashReporting(crashReports)
        Telemetry.shared.setAnalytics(analytics)
        consentAsked = true
        dismiss()
    }
}
