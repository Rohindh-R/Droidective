import SwiftUI

/// One-time privacy disclosure shown on first launch (after the welcome tour).
/// Both crash reporting and analytics start ON here and are recommended; nothing
/// is sent until Continue is pressed. Toggleable later in Settings → Privacy.
struct TelemetryConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("telemetryConsentAsked") private var consentAsked = false
    @State private var crashReports = true
    @State private var analytics = true

    private var bothOn: Bool { crashReports && analytics }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            disclosure
            VStack(spacing: 0) {
                ConsentRow(
                    icon: "ladybug.fill",
                    title: "Anonymous crash reports",
                    subtitle: "Helps fix the bugs you actually hit.",
                    isOn: $crashReports
                )
                Divider().overlay(Color.borderSubtle)
                ConsentRow(
                    icon: "chart.bar.fill",
                    title: "Anonymous usage analytics",
                    subtitle: "Which tools get used, so the useful ones improve.",
                    isOn: $analytics
                )
            }
            .padding(.horizontal, 16)
            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.borderSubtle, lineWidth: 1))

            recommendation
            footer
            actions
        }
        .padding(28)
        .frame(width: 480)
        .background(Color.bgRoot)
        .onAppear { crashReports = Telemetry.shared.crashReportingEnabled }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.brandAccent)
                .frame(width: 44, height: 44)
                .background(Color.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("Help shape Droidective")
                    .font(.title2.bold())
                Text("Two anonymous signals. You're in control.")
                    .font(.subheadline)
                    .foregroundStyle(.textMuted)
            }
        }
    }

    private var disclosure: some View {
        Text("Droidective can send **anonymous** diagnostics to help improve it. No device serials, package names, file paths, IP addresses, or command contents are ever sent.")
            .font(.callout)
            .foregroundStyle(.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var recommendation: some View {
        HStack(spacing: 10) {
            Image(systemName: bothOn ? "checkmark.seal.fill" : "lightbulb.fill")
                .foregroundStyle(.brandAccent)
            Text(bothOn
                 ? "Thank you — keeping both on is the biggest help, and it stays fully anonymous."
                 : "We recommend keeping both on. It's fully anonymous and shapes what we build next.")
                .font(.footnote)
                .foregroundStyle(.textMain)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        Text("You can change this anytime in Settings → Privacy.")
            .font(.footnote)
            .foregroundStyle(.textMuted)
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Continue") { finish() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(.brandAccent)
        }
    }

    private func finish() {
        Telemetry.shared.setCrashReporting(crashReports)
        Telemetry.shared.setAnalytics(analytics)
        consentAsked = true
        dismiss()
    }
}

/// One toggle row: leading icon, title + a "Recommended" badge, subtitle, switch.
private struct ConsentRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.brandAccent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                    RecommendedBadge()
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.brandAccent)
        }
        .padding(.vertical, 14)
    }
}

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.brandAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.brandAccent.opacity(0.14), in: Capsule())
    }
}
