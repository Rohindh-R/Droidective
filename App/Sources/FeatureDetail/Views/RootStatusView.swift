import ADBKit
import SwiftUI

/// Root probe: a verdict header plus the individual signals behind it. A
/// working `su` shell is the definitive proof; the weaker signals (su binary,
/// Magisk, build tags, SELinux) are shown for context.
struct RootStatusView: View {
    @Environment(AppState.self) private var state
    @State private var status: RootStatus?

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to check its root status.")
                )
            } else if let status {
                content(status)
            } else {
                ProgressView("Probing root…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.targetSerials.first ?? "") {
            await load()
        }
    }

    private func content(_ status: RootStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(status)
                VStack(spacing: 0) {
                    ForEach(status.signals) { signal in
                        signalRow(signal)
                        if signal.id != status.signals.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ status: RootStatus) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon(status))
                .font(.system(size: 38))
                .foregroundStyle(tint(status))
            VStack(alignment: .leading, spacing: 2) {
                Text(status.summary)
                    .font(.title2).bold()
                Text(status.hasRootShell
                    ? "A root shell is available over adb."
                    : "Root-only features need a granted su shell.")
                    .font(.callout)
                    .foregroundStyle(.textMuted)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
        }
    }

    private func signalRow(_ signal: RootSignal) -> some View {
        HStack(spacing: 10) {
            Image(systemName: signal.indicatesRoot ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(signal.indicatesRoot ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
            VStack(alignment: .leading, spacing: 1) {
                Text(signal.name)
                Text(signal.detail)
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func icon(_ status: RootStatus) -> String {
        if status.hasRootShell { return "checkmark.shield.fill" }
        return status.likelyRooted ? "exclamationmark.shield.fill" : "lock.shield"
    }

    private func tint(_ status: RootStatus) -> Color {
        if status.hasRootShell { return .brandAccent }
        return status.likelyRooted ? .warning : .textMuted
    }

    private func load() async {
        status = nil
        guard let serial = state.targetSerials.first else { return }
        let result = await CommandLog.userInitiated(feature: "root-status") {
            await state.env.engine.root.detect(serial: serial)
        }
        guard !Task.isCancelled else { return }
        status = result
    }
}
