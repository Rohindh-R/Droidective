import ADBKit
import SwiftUI

/// Expandable list of recent user-initiated adb commands.
struct CommandLogView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [CommandLogEntry] = []
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Command Log")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task {
                        await state.env.commandLog.clear()
                        await refresh()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                Button("Close") { dismiss() }
            }
            .padding(12)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "No commands yet",
                    systemImage: "terminal",
                    description: Text("Commands you run appear here with their output.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if expanded.contains(entry.id) {
                                expanded.remove(entry.id)
                            } else {
                                expanded.insert(entry.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption)
                                Text(entry.command)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text(exitLabel(entry))
                                    .font(.caption)
                                    .foregroundStyle(entry.exitCode == 0 ? .green : .red)
                                Text(entry.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expanded.contains(entry.id) {
                            if !entry.stdout.isEmpty {
                                Text(entry.stdout)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                            if !entry.stderr.isEmpty {
                                Text(entry.stderr)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .task { await refresh() }
    }

    private func refresh() async {
        entries = await state.env.commandLog.snapshot()
    }

    private func exitLabel(_ entry: CommandLogEntry) -> String {
        let code = entry.exitCode.map(String.init) ?? "killed"
        let ms = Int(entry.duration.components.seconds * 1000)
            + Int(entry.duration.components.attoseconds / 1_000_000_000_000_000)
        return "exit \(code) · \(ms)ms"
    }
}
