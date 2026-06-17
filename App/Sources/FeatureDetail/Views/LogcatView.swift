import ADBKit
import SwiftUI

/// Live logcat stream with level/app/text filters, pause, and a capped ring
/// buffer. The whole stream lifecycle hangs off `.task(id:)` — changing any
/// filter (or device) cancels the old stream and starts a fresh one.
struct LogcatView: View {
    static let maxLines = 5000

    @Environment(AppState.self) private var state
    @State private var lines: [LogLine] = []
    @State private var paused = false
    @State private var level = "All"
    @State private var packageFilter: String?
    @State private var tagFilter: String?
    @State private var search = ""
    @State private var waitingForPackage: String?
    @State private var streamingPid: Int?
    /// True while pinned to the bottom; scrolling up unpins.
    @State private var following = true
    @State private var newSinceUnfollow = 0

    private static let levels: [(value: String, label: String)] = [
        ("All", "All levels"), ("V", "Verbose"), ("D", "Debug"),
        ("I", "Info"), ("W", "Warning"), ("E", "Error"), ("F", "Fatal"),
    ]

    private var taskKey: String {
        "\(state.selectedSerial ?? "none")|\(level)|\(packageFilter ?? "all")"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            statusBar
            Divider()
            logList
        }
        .task(id: taskKey) { await streamLoop() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            LabeledContent("Level") {
                Picker("Level", selection: $level) {
                    ForEach(Self.levels, id: \.value) { item in
                        Text(item.label).tag(item.value)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .font(.callout)

            LabeledContent("App") {
                Picker("App", selection: $packageFilter) {
                    Text("All apps").tag(String?.none)
                    ForEach(state.bundles) { bundle in
                        Text(bundle.nickname).tag(Optional(bundle.packageId))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            .font(.callout)

            TextField("Search lines…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? "Resume (new lines are dropped while paused)" : "Pause")

            Button {
                export()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export buffer to ~/Downloads/Droidective")
            .disabled(lines.isEmpty)

            Button {
                lines.removeAll()
                newSinceUnfollow = 0
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// One line of truth about what the stream is actually doing.
    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let tagFilter {
                Button {
                    self.tagFilter = nil
                } label: {
                    HStack(spacing: 3) {
                        Text("tag: \(tagFilter)")
                        Image(systemName: "xmark.circle.fill")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.tint.opacity(0.15), in: Capsule())
                .help("Remove tag filter")
            }
            Spacer()
            if !search.isEmpty {
                Text("\(visibleLines.count) of \(lines.count) lines match")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(lines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4))
    }

    private var statusColor: Color {
        if state.targetSerials.isEmpty { return .gray }
        if waitingForPackage != nil { return .orange }
        return paused ? .yellow : .green
    }

    private var statusText: String {
        if state.targetSerials.isEmpty { return "No device connected" }
        if let waiting = waitingForPackage {
            return "Waiting for \(bundleName(waiting)) to launch — open it on the device"
        }
        var parts: [String] = [paused ? "Paused" : "Streaming"]
        if level != "All" {
            parts.append("\(Self.levels.first { $0.value == level }?.label ?? level) and above")
        }
        if let packageFilter {
            let pid = streamingPid.map { " (pid \($0))" } ?? ""
            parts.append("\(bundleName(packageFilter))\(pid)")
        }
        return parts.joined(separator: " · ")
    }

    private func bundleName(_ packageId: String) -> String {
        state.bundles.first { $0.packageId == packageId }?.nickname ?? packageId
    }

    // MARK: - Log list

    private var visibleLines: [LogLine] {
        lines.filter { line in
            if let tagFilter, line.tag != tagFilter { return false }
            if !search.isEmpty && !line.raw.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleLines) { line in
                        Text(attributedDisplay(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            .contextMenu {
                                if !line.tag.isEmpty {
                                    Button("Filter by tag \"\(line.tag)\"") {
                                        tagFilter = line.tag
                                    }
                                }
                                Button("Copy line") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(line.raw, forType: .string)
                                }
                            }
                    }
                    // Bottom sentinel: visible = pinned to bottom.
                    Color.clear
                        .frame(height: 1)
                        .id("logcat-bottom")
                        .onAppear {
                            following = true
                            newSinceUnfollow = 0
                        }
                        .onDisappear { following = false }
                }
                .padding(8)
            }
            .background(.background)
            .overlay { emptyOverlay }
            .overlay(alignment: .bottom) {
                if !following && newSinceUnfollow > 0 {
                    Button {
                        proxy.scrollTo("logcat-bottom", anchor: .bottom)
                        following = true
                        newSinceUnfollow = 0
                    } label: {
                        Label("\(newSinceUnfollow) new lines", systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: lines.last?.id) {
                if following, !paused {
                    proxy.scrollTo("logcat-bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Search matches get a highlight instead of vanishing into the filter.
    private func attributedDisplay(_ line: LogLine) -> AttributedString {
        var attributed = AttributedString(display(line))
        guard !search.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: search, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.35)
            searchStart = range.upperBound
        }
        return attributed
    }

    private func export() {
        guard let file = state.askSaveLocation(
            suggestedName: "logcat_\(ScreenCaptureService.stamp()).txt"
        ) else { return }
        let content = visibleLines.map(\.raw).joined(separator: "\n")
        do {
            try Data(content.utf8).write(to: file)
            state.showToast(Toast(message: "Exported \(visibleLines.count) lines", ok: true, revealPath: file.path))
        } catch {
            state.showToast(Toast(message: "Export failed: \(error.localizedDescription)", ok: false))
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if state.targetSerials.isEmpty {
            ContentUnavailableView(
                "No device connected", systemImage: "iphone.slash",
                description: Text("Connect a device to stream logs.")
            )
        } else if let waiting = waitingForPackage, lines.isEmpty {
            ContentUnavailableView(
                "\(bundleName(waiting)) isn't running", systemImage: "app.dashed",
                description: Text("Open the app on the device — streaming starts automatically.")
            )
        } else if lines.isEmpty {
            ContentUnavailableView(
                "No log output", systemImage: "scroll",
                description: Text("Logs will appear here as the device emits them.")
            )
        }
    }

    private func display(_ line: LogLine) -> String {
        line.level.isEmpty
            ? line.raw
            : "\(line.time)  \(line.pid)  \(line.level)/\(line.tag): \(line.message)"
    }

    private func color(for level: String) -> Color {
        switch level {
        case "E", "F": return .red
        case "W": return .orange
        case "I": return .primary
        default: return .secondary
        }
    }

    // MARK: - Streaming

    /// Owned by `.task(id:)`: cancelled and restarted whenever the device,
    /// level, or app filter changes. Outer loop survives app restarts (pid
    /// changes) and transient stream deaths.
    private func streamLoop() async {
        lines.removeAll()
        waitingForPackage = nil
        streamingPid = nil
        guard let serial = state.targetSerials.first else { return }

        let streamer = LogcatStreamer(client: state.env.client)
        defer {
            Task { await streamer.stop() }
            waitingForPackage = nil
            streamingPid = nil
        }

        // Record the launched logcat command once per filter/device change so
        // it shows in the feature's Recent tab; the pid polling stays out.
        var recordedCommand = false
        while !Task.isCancelled {
            // An app filter means *that app's* logs: if it isn't running,
            // wait for it instead of silently streaming everything.
            var pid: Int?
            if let packageId = packageFilter {
                while !Task.isCancelled {
                    pid = try? await streamer.resolvePid(serial: serial, packageId: packageId)
                    if pid != nil { break }
                    waitingForPackage = packageId
                    try? await Task.sleep(for: .seconds(2))
                }
                waitingForPackage = nil
                if Task.isCancelled { return }
                streamingPid = pid
            }

            let filters = LogcatFilters(level: level == "All" ? nil : level, pid: pid)
            guard let stream = try? await streamer.start(serial: serial, filters: filters) else { return }

            if !recordedCommand {
                recordedCommand = true
                let command = "adb " + LogcatLineParser.buildArgs(serial: serial, filters: filters).joined(separator: " ")
                await CommandLog.userInitiated(feature: "logcat") {
                    await state.env.commandLog.record(
                        command: command, exitCode: 0, duration: .zero, stdout: "", stderr: ""
                    )
                }
            }

            // `logcat --pid` goes silent forever if the app dies or relaunches
            // with a new pid — watch for that and stop the streamer, which
            // ends the consumption loop and re-enters the wait above.
            var pidWatcher: Task<Void, Never>?
            if let packageId = packageFilter, let activePid = pid {
                pidWatcher = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        let current = try? await streamer.resolvePid(serial: serial, packageId: packageId)
                        if current != activePid {
                            await streamer.stop()
                            break
                        }
                    }
                }
            }

            for await batch in stream {
                if Task.isCancelled { break }
                if paused { continue }
                lines.append(contentsOf: batch)
                if !following {
                    newSinceUnfollow += batch.count
                }
                if lines.count > Self.maxLines {
                    lines.removeFirst(lines.count - Self.maxLines)
                }
            }
            pidWatcher?.cancel()
            streamingPid = nil
            if Task.isCancelled { return }
            // Unfiltered stream ended (adb hiccup) — brief backoff, retry.
            if packageFilter == nil {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
