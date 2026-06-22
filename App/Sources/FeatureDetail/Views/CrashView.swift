import ADBKit
import AppKit
import SwiftUI

/// Most recent crash from the device, formatted for Slack/Jira/plain copy.
struct CrashView: View {
    @Environment(AppState.self) private var state
    @State private var format = CrashFormat.plain
    @State private var crash: String?
    @State private var loading = false
    @State private var refreshToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Format", selection: $format) {
                    ForEach(CrashFormat.allCases, id: \.self) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }
                .frame(maxWidth: 160)
                .labelsHidden()

                Button {
                    refreshToken += 1
                } label: {
                    Label(loading ? "Checking…" : "Fetch last crash", systemImage: "arrow.clockwise")
                }
                .disabled(loading || state.targetSerials.isEmpty)

                if let crash {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(crash, forType: .string)
                        state.showToast(Toast(message: "Crash copied", ok: true))
                    } label: {
                        Label("Copy", systemImage: "doc.on.clipboard")
                    }
                }
                Spacer()
            }
            .padding(8)
            Divider()

            if let crash {
                ScrollView {
                    Text(crash)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            } else {
                ContentUnavailableView(
                    "No crashes detected",
                    systemImage: "exclamationmark.triangle",
                    description: Text(state.targetSerials.isEmpty
                        ? "Connect a device to check for crashes."
                        : "Fatal errors and crash reports will appear here. Hit Fetch to check the crash buffer.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(format.rawValue)|\(state.targetSerials.first ?? "")|\(refreshToken)") {
            await fetch()
        }
    }

    /// Structured: cancelled (and restarted) by `.task(id:)` whenever the
    /// format, device, or refresh token changes — no racing writers.
    private func fetch() async {
        crash = nil
        guard let serial = state.targetSerials.first else { return }
        loading = true
        defer { loading = false }
        let result = await CommandLog.userInitiated(feature: "crash-catcher") {
            try? await state.env.engine.crash.lastCrash(serial: serial, format: format)
        }
        if !Task.isCancelled {
            crash = result
        }
    }
}
