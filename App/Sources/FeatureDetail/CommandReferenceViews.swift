import ADBKit
import AppKit
import SwiftUI

/// Small clipboard button with a transient checkmark, used by the command
/// reference rows.
struct CommandCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.brandAccent : Color.textMuted)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Copy command")
    }
}

/// The static list of adb commands a feature runs — each with an optional note
/// on what it does and a one-click copy.
struct CommandReferenceList: View {
    let commands: [FeatureCommand]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(commands) { command in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = command.note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 6)
                    CommandCopyButton(text: command.command)
                }
            }
        }
    }
}

/// One expandable command-log entry: the command, its exit code/duration, and
/// (when expanded) its stdout/stderr. Shared by the global Command Log and the
/// per-feature log.
struct CommandLogRow: View {
    let entry: CommandLogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.textMuted)
                    Text(entry.command)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Text(Self.exitLabel(entry))
                        .font(.caption)
                        .foregroundStyle(entry.exitCode == 0 ? Color.brandAccent : Color.red)
                    Text(entry.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !entry.stdout.isEmpty {
                    outputBlock(entry.stdout, tint: nil)
                }
                if !entry.stderr.isEmpty {
                    outputBlock(entry.stderr, tint: .red)
                }
                if entry.stdout.isEmpty && entry.stderr.isEmpty {
                    Text("(no output)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder
    private func outputBlock(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(tint ?? .primary)
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .textMuted).opacity(tint == nil ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    static func exitLabel(_ entry: CommandLogEntry) -> String {
        let code = entry.exitCode.map(String.init) ?? "killed"
        let ms = Int(entry.duration.components.seconds * 1000)
            + Int(entry.duration.components.attoseconds / 1_000_000_000_000_000)
        return "exit \(code) · \(ms)ms"
    }
}

/// The commands one feature actually ran, most-recent-first, filtered from the
/// shared command log. Refreshes on appear and whenever the feature's last
/// result changes (action features); `showsHeader` adds refresh/clear controls
/// for the toolbar panel.
struct FeatureCommandLog: View {
    @Environment(AppState.self) private var state
    let featureID: String
    var showsHeader = false

    @State private var entries: [CommandLogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 4) {
                    Text("Recent runs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.textMuted)
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Refresh")
                    if !entries.isEmpty {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Clear this feature's history")
                    }
                }
            }

            if entries.isEmpty {
                Text("No runs yet — run this feature to see its commands and output here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(entries) { entry in
                    CommandLogRow(entry: entry)
                }
            }
        }
        .task(id: state.lastResults[featureID]?.at) { await refresh() }
        .task(id: featureID) {
            // Poll while visible: view-features record commands directly on the
            // log without posting a lastResults change, so refresh on a timer
            // to surface them. Keyed on featureID so switching features restarts
            // the loop with the new id instead of showing the old feature's log.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        entries = await state.env.commandLog.snapshot(featureID: featureID)
    }

    private func clear() async {
        await state.env.commandLog.clear(featureID: featureID)
        await refresh()
    }
}

/// The tab selected in the bottom command bar.
enum CommandBarTab: String, CaseIterable, Hashable {
    case recent, commands, terminal
}

/// Command bar pinned inside the bottom of every feature pane: a single strip
/// with Recent / Commands / Terminal tabs, the feature's ⓘ note, and one
/// collapse toggle. Collapsed shows only the tab strip; expanded reveals the
/// active tab. ⌘J hides the whole bar.
struct FeatureCommandBar: View {
    @Environment(AppState.self) private var state
    @AppStorage("commandBarHeight") private var commandBarHeight = 220.0
    @AppStorage("showFeatureNotes") private var showFeatureNotes = false
    let feature: FeatureDef

    var body: some View {
        let commands = FeatureRegistry.commands(for: feature.id)
        VStack(spacing: 0) {
            if state.commandBarExpanded {
                ResizeHandle(value: $commandBarHeight, range: 120...520, axis: .vertical, inverted: true)
            } else {
                Divider()
            }
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    tabButton(.recent, "Recent")
                    tabButton(.terminal, "Terminal")
                    tabButton(.commands, commands.count > 1 ? "Commands" : "Command")
                }

                Spacer()

                if state.commandBarExpanded && state.commandBarTab == .terminal {
                    Button {
                        state.terminalSession.kill()
                        withAnimation(.easeInOut(duration: 0.15)) { state.commandBarExpanded = false }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.textMuted)
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Kill the terminal & minimize")
                }

                if FeatureRegistry.howTo(for: feature.id) != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showFeatureNotes.toggle() }
                    } label: {
                        Image(systemName: showFeatureNotes ? "info.circle.fill" : "info.circle")
                            .foregroundStyle(showFeatureNotes ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showFeatureNotes ? "Hide the how-it-works note" : "Show the how-it-works note")
                }

                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: state.commandBarExpanded ? "chevron.down" : "chevron.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.textMuted)
                        .frame(width: 34, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.commandBarExpanded ? "Minimize command bar (⌘J)" : "Expand command bar (⌘J)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if state.commandBarExpanded {
                Divider()
                tabContent(commands: commands)
                    .frame(height: commandBarHeight)
            }
        }
        .background(.bgSurface)
    }

    private func tabButton(_ tab: CommandBarTab, _ title: String) -> some View {
        let active = state.commandBarExpanded && state.commandBarTab == tab
        return Button {
            selectTab(tab)
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    active ? AnyShapeStyle(.brandAccent.opacity(0.15)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(active ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMuted))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Any tab click opens the bar and switches to that tab. Clicking the
    /// active tab while open is a no-op (not a toggle), so the bar never
    /// collapses unexpectedly — the chevron and ⌘J own collapsing.
    private func selectTab(_ tab: CommandBarTab) {
        state.commandBarTab = tab
        if !state.commandBarExpanded {
            withAnimation(.easeInOut(duration: 0.15)) { state.commandBarExpanded = true }
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.15)) { state.commandBarExpanded.toggle() }
    }

    @ViewBuilder
    private func tabContent(commands: [FeatureCommand]) -> some View {
        switch state.commandBarTab {
        case .recent:
            ScrollView {
                FeatureCommandLog(featureID: feature.id)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .commands:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if commands.count > 1 {
                        HStack {
                            Spacer()
                            CommandCopyButton(text: commands.map(\.command).joined(separator: "\n"))
                        }
                    }
                    CommandReferenceList(commands: commands)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .terminal:
            NativeTerminalView(session: state.terminalSession, serial: state.targetSerials.first)
        }
    }
}

