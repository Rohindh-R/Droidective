import ADBKit
import AppKit
import SwiftUI

/// Bug Report — assemble a shareable zip (screenshot + recent logcat + device
/// info, plus the app version when a bundle is selected) and reveal it in
/// Finder, ready to attach to a ticket.
struct BugReportView: View {
    @Environment(AppState.self) private var state

    private var bundle: AppBundle? { state.selectedBundle }
    private var lastReport: (result: FeatureResult, at: Date)? { state.lastResults["bug-report"] }

    var body: some View {
        HubColumn {
            HubSection("What's included", subtitle: "A single zip you can drop straight into a bug ticket.") {
                VStack(spacing: 0) {
                    contentRow("camera", "Screenshot", "The current screen")
                    Divider()
                    contentRow("scroll", "Logcat", "The last 2,000 log lines")
                    Divider()
                    contentRow("info.circle", "Device info", "Model, Android version, ABI, serial")
                    Divider()
                    contentRow(
                        "shippingbox", "App version",
                        bundle.map { "Included for \($0.nickname)" } ?? "Select a bundle in the bar to include it"
                    )
                }
            }

            HubSection("Generate") {
                Button { generate() } label: {
                    Label("Generate bug report", systemImage: "doc.zipper")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.targetSerials.isEmpty || state.isRunningFeature)

                if state.isRunningFeature {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Collecting screenshot, logs, and device info…").foregroundStyle(.textMuted)
                    }
                } else if state.targetSerials.isEmpty {
                    Text("Connect a device first.").font(.footnote).foregroundStyle(.textMuted)
                }

                if let last = lastReport, last.result.ok, let path = last.result.revealPath {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.brandAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bug report saved").foregroundStyle(.textMain)
                            Text((path as NSString).lastPathComponent)
                                .font(.footnote).foregroundStyle(.textMuted)
                        }
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            }
        }
    }

    private func contentRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.textMuted).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.textMain)
                Text(detail).font(.footnote).foregroundStyle(.textMuted)
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private func generate() {
        guard let feature = FeatureRegistry.byID["bug-report"] else { return }
        Task { await state.run(feature: feature, params: [:]) }
    }
}
