import ADBKit
import Charts
import SwiftUI

/// Live performance monitor: per-core CPU, system + app RAM, app FPS, and a
/// filterable per-process table — sampled over adb on a timer while recording,
/// charted, and exportable as JSON + CSV.
struct PerformanceView: View {
    @Environment(AppState.self) private var state

    enum Phase { case idle, recording, paused }
    enum SortKey: String, CaseIterable { case ram = "RAM", cpu = "CPU", name = "Name" }

    /// One charted sample. `totalCpu` is the aggregate `cpu` line.
    struct Sample: Identifiable {
        let id = UUID()
        let elapsed: TimeInterval
        let cores: [CpuCoreLoad]
        let ramUsedKb: Int?
        let ramTotalKb: Int?
        let appFps: Double?
        let appJankPercent: Double?
        let appPssKb: Int?
        let downloadBps: Double?
        let uploadBps: Double?
        var totalCpu: Double? { cores.first { $0.core < 0 }?.usagePercent }
        var perCore: [CpuCoreLoad] { cores.filter { $0.core >= 0 } }
    }

    @State private var phase: Phase = .idle
    @State private var samples: [Sample] = []
    @State private var processes: [ProcessLoad] = []
    @State private var startDate: Date?
    @State private var sampler: Task<Void, Never>?
    @State private var filter = ""
    @State private var sortKey: SortKey = .ram
    /// Hovered x (elapsed seconds), shared across charts for a synced crosshair.
    @State private var selectedElapsed: Double?

    /// Poll cadence. dumpsys meminfo (per-process) is heavy, so it runs every
    /// other tick while the lighter CPU/RAM/FPS counters run every tick.
    private static let interval: Duration = .seconds(2)
    private static let chartWindow = 150
    private static let maxSamples = 5000

    private var serial: String? { state.targetSerials.first }
    private var packageId: String? { state.selectedBundle?.packageId }
    private var recentSamples: [Sample] { Array(samples.suffix(Self.chartWindow)) }

    /// The sample nearest the hovered x, for the crosshair tooltip.
    private var selectedSample: Sample? {
        guard let selectedElapsed else { return nil }
        return recentSamples.min { abs($0.elapsed - selectedElapsed) < abs($1.elapsed - selectedElapsed) }
    }

    /// Dynamic CPU ceiling: fits the busiest core (+20% headroom), floored at
    /// 10% so a near-idle device doesn't over-zoom, capped at 100%.
    private var cpuDomainMax: Double {
        let peak = recentSamples.flatMap(\.perCore).map(\.usagePercent).max() ?? 100
        return min(100, max(10, (peak * 1.2).rounded(.up)))
    }

    /// FPS ceiling that always keeps the 60 fps line visible, growing if the
    /// app renders faster.
    private var fpsDomainMax: Double {
        max(70, ((recentSamples.compactMap(\.appFps).max() ?? 60) * 1.1).rounded(.up))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .onChange(of: serial) {
            stop()
            samples = []
            processes = []
        }
        .onDisappear {
            sampler?.cancel()
            state.recordingActive = false
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { toggleRecord() } label: {
                Label(recordTitle, systemImage: recordIcon).frame(minWidth: 78)
            }
            .buttonStyle(.borderedProminent)
            .tint(phase == .recording ? .orange : .red)
            .disabled(serial == nil)
            .help("Start, pause, or resume sampling")

            Button { stop() } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(phase == .idle)
            .help("Stop recording")

            Button { export() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(samples.isEmpty)
            .help("Export the recording as JSON + CSV")

            Spacer()

            if let last = samples.last {
                summaryChips(last)
            }
            Text(statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(phase == .recording ? .textMain : .textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var recordTitle: String {
        switch phase {
        case .idle: return "Record"
        case .recording: return "Pause"
        case .paused: return "Resume"
        }
    }

    private var recordIcon: String {
        switch phase {
        case .idle: return "record.circle"
        case .recording: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    private var statusText: String {
        let elapsed = samples.last?.elapsed ?? 0
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let clock = String(format: "%02d:%02d", minutes, seconds)
        switch phase {
        case .idle: return samples.isEmpty ? "Ready" : "Stopped · \(clock)"
        case .recording: return "Recording · \(clock)"
        case .paused: return "Paused · \(clock)"
        }
    }

    private func summaryChips(_ sample: Sample) -> some View {
        HStack(spacing: 8) {
            chip("CPU", sample.totalCpu.map { String(format: "%.0f%%", $0) } ?? "—", .blue)
            chip("RAM", sample.ramUsedKb.map { "\(mb($0)) MB" } ?? "—", .brandAccent)
            chip("NET", "↓\(speedCompact(sample.downloadBps)) ↑\(speedCompact(sample.uploadBps))", .teal)
            if packageId != nil {
                chip("FPS", sample.appFps.map { String(format: "%.0f", $0) } ?? "—", .purple)
            }
        }
    }

    private func chip(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if serial == nil {
            ContentUnavailableView(
                "No device connected", systemImage: "iphone.slash",
                description: Text("Connect a device to monitor its performance.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if samples.isEmpty && processes.isEmpty {
            ContentUnavailableView(
                "Nothing recorded yet", systemImage: "chart.line.uptrend.xyaxis",
                description: Text(emptyHint)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cpuCard
                    systemRamCard
                    if packageId != nil { appMemoryCard }
                    netCard
                    if packageId != nil { fpsCard }
                    processCard
                }
                .padding(14)
            }
        }
    }

    private var emptyHint: String {
        packageId == nil
            ? "Press Record to sample per-core CPU, system RAM, and per-process usage. Select an app bundle to also chart its FPS and memory."
            : "Press Record to sample per-core CPU, RAM, the app's FPS, and per-process usage."
    }

    // MARK: - Charts

    private var cpuCard: some View {
        card("CPU — per core", subtitle: "% utilization") {
            Chart(recentSamples) { sample in
                ForEach(sample.perCore) { core in
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("CPU", core.usagePercent)
                    )
                    .foregroundStyle(by: .value("Core", core.label))
                    .interpolationMethod(.monotone)
                }
                hoverRule { "\(Int($0.elapsed))s · \($0.totalCpu.map { String(format: "%.0f%%", $0) } ?? "—")" }
            }
            .chartYScale(domain: 0...cpuDomainMax)
            .chartXSelection(value: $selectedElapsed)
            .chartXAxisLabel("seconds")
            .chartLegend(position: .bottom, spacing: 6)
            .frame(height: 160)
        }
    }

    private var systemRamCard: some View {
        card("System RAM", subtitle: "MB used") {
            Chart(recentSamples) { sample in
                if let used = sample.ramUsedKb {
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("MB", Double(used) / 1024.0)
                    )
                    .foregroundStyle(.brandAccent)
                    .interpolationMethod(.monotone)
                }
                hoverRule { "\(Int($0.elapsed))s · \($0.ramUsedKb.map { "\(mb($0)) MB" } ?? "—")" }
            }
            .chartXSelection(value: $selectedElapsed)
            .chartXAxisLabel("seconds")
            .frame(height: 150)
        }
    }

    private var appMemoryCard: some View {
        card("App memory", subtitle: "MB · PSS") {
            Chart(recentSamples) { sample in
                if let pss = sample.appPssKb {
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("MB", Double(pss) / 1024.0)
                    )
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
                }
                hoverRule { "\(Int($0.elapsed))s · \($0.appPssKb.map { "\(mb($0)) MB" } ?? "—")" }
            }
            .chartXSelection(value: $selectedElapsed)
            .chartXAxisLabel("seconds")
            .frame(height: 150)
            .overlay {
                if !recentSamples.contains(where: { $0.appPssKb != nil }) {
                    Text("Waiting for the app's memory…")
                        .font(.callout).foregroundStyle(.textMuted)
                }
            }
        }
    }

    private var fpsCard: some View {
        card("App FPS", subtitle: "rendered frames/sec · jank \(latestJank)") {
            Chart {
                ForEach(recentSamples) { sample in
                    if let fps = sample.appFps {
                        LineMark(
                            x: .value("Time", sample.elapsed),
                            y: .value("FPS", fps)
                        )
                        .foregroundStyle(.purple)
                        .interpolationMethod(.monotone)
                    }
                }
                RuleMark(y: .value("Target", 60))
                    .foregroundStyle(.brandAccent.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                hoverRule { "\(Int($0.elapsed))s · \($0.appFps.map { String(format: "%.0f fps", $0) } ?? "—")" }
            }
            .chartYScale(domain: 0...fpsDomainMax)
            .chartXSelection(value: $selectedElapsed)
            .chartXAxisLabel("seconds")
            .frame(height: 160)
            .overlay {
                if !recentSamples.contains(where: { $0.appFps != nil }) {
                    Text("Waiting for rendered frames — interact with the app on the device.")
                        .font(.callout)
                        .foregroundStyle(.textMuted)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }

    private var latestJank: String {
        samples.last?.appJankPercent.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    private var netCard: some View {
        card("Network", subtitle: "↓ \(speed(samples.last?.downloadBps))  ↑ \(speed(samples.last?.uploadBps))") {
            Chart(recentSamples) { sample in
                if let down = sample.downloadBps {
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("KB/s", down / 1024.0)
                    )
                    .foregroundStyle(by: .value("Series", "Download"))
                    .interpolationMethod(.monotone)
                }
                if let up = sample.uploadBps {
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("KB/s", up / 1024.0)
                    )
                    .foregroundStyle(by: .value("Series", "Upload"))
                    .interpolationMethod(.monotone)
                }
                hoverRule { "\(Int($0.elapsed))s · ↓\(self.speedShort($0.downloadBps)) ↑\(self.speedShort($0.uploadBps))" }
            }
            .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.brandAccent])
            .chartXSelection(value: $selectedElapsed)
            .chartXAxisLabel("seconds")
            .chartLegend(position: .bottom, spacing: 6)
            .frame(height: 160)
        }
    }

    @ChartContentBuilder
    private func hoverRule(_ label: (Sample) -> String) -> some ChartContent {
        if let sample = selectedSample {
            RuleMark(x: .value("Time", sample.elapsed))
                .foregroundStyle(Color.textMuted.opacity(0.4))
                .annotation(
                    position: .top,
                    alignment: .center,
                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                ) {
                    Text(label(sample))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 5))
                }
        }
    }

    private func speedShort(_ bytesPerSec: Double?) -> String {
        guard let value = bytesPerSec, value > 0 else { return "0" }
        return value >= 1_048_576
            ? String(format: "%.1fMB/s", value / 1_048_576)
            : String(format: "%.0fKB/s", value / 1024)
    }

    // MARK: - Process table

    private var processCard: some View {
        card("Processes", subtitle: "\(filteredProcesses.count) of \(processes.count)") {
            VStack(spacing: 6) {
                HStack {
                    TextField("Filter by name…", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Picker("Sort", selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                processHeader
                Divider()
                if filteredProcesses.isEmpty {
                    Text(processes.isEmpty ? "Per-process data appears while recording." : "No processes match the filter.")
                        .font(.callout)
                        .foregroundStyle(.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filteredProcesses) { process in
                        processRow(process)
                    }
                }
            }
        }
    }

    private var processHeader: some View {
        HStack(spacing: 8) {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("PID").frame(width: 64, alignment: .trailing)
            Text("CPU").frame(width: 56, alignment: .trailing)
            Text("RAM").frame(width: 80, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.textMuted)
    }

    private func processRow(_ process: ProcessLoad) -> some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(process.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.textMuted)
                .frame(width: 64, alignment: .trailing)
            Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.caption.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
            Text(process.pssKb.map { "\(mb($0)) MB" } ?? "—")
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private var filteredProcesses: [ProcessLoad] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = trimmed.isEmpty
            ? processes
            : processes.filter { $0.name.lowercased().contains(trimmed) }
        switch sortKey {
        case .ram: return matched.sorted { ($0.pssKb ?? 0) > ($1.pssKb ?? 0) }
        case .cpu: return matched.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
        case .name: return matched.sorted { $0.name < $1.name }
        }
    }

    // MARK: - Building blocks

    private func card(_ title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.textMuted)
                Spacer()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.borderSubtle, lineWidth: 1))
    }

    private func mb(_ kb: Int) -> String {
        String(format: "%.0f", Double(kb) / 1024.0)
    }

    /// "1.20 MB/s" / "340 KB/s" — for card subtitles.
    private func speed(_ bytesPerSec: Double?) -> String {
        guard let value = bytesPerSec, value > 0 else { return "0 KB/s" }
        return value >= 1_048_576
            ? String(format: "%.2f MB/s", value / 1_048_576)
            : String(format: "%.0f KB/s", value / 1024)
    }

    /// "1.2M" / "340K" — compact, for the summary chip.
    private func speedCompact(_ bytesPerSec: Double?) -> String {
        guard let value = bytesPerSec, value > 0 else { return "0" }
        if value >= 1_048_576 { return String(format: "%.1fM", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0fK", value / 1024) }
        return String(format: "%.0fB", value)
    }

    // MARK: - Recording

    private func toggleRecord() {
        switch phase {
        case .idle:
            samples = []
            startDate = Date()
            phase = .recording
            state.recordingActive = true
            launchSampler()
        case .recording:
            phase = .paused
            sampler?.cancel()
            sampler = nil
        case .paused:
            phase = .recording
            state.recordingActive = true
            launchSampler()
        }
    }

    private func stop() {
        phase = .idle
        sampler?.cancel()
        sampler = nil
        state.recordingActive = false
    }

    private func launchSampler() {
        guard let serial else { return }
        let package = packageId
        sampler?.cancel()
        sampler = Task { @MainActor in
            // Drop stale deltas so the first post-(re)start sample isn't a
            // spike measured against a long-ago reading.
            await state.env.engine.performance.reset()
            var tick = 0
            while !Task.isCancelled {
                let includeProcesses = tick % 2 == 0
                let poll = await state.env.engine.performance.poll(
                    serial: serial, packageId: package, includeProcesses: includeProcesses
                )
                if Task.isCancelled { break }
                if includeProcesses { processes = poll.processes }
                // The first poll after a reset has no deltas (empty cores) — skip it.
                if !poll.cores.isEmpty {
                    appendSample(poll)
                }
                tick += 1
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func appendSample(_ poll: PerformanceService.PerfPoll) {
        let elapsed = Date().timeIntervalSince(startDate ?? Date())
        samples.append(Sample(
            elapsed: elapsed,
            cores: poll.cores,
            ramUsedKb: poll.ramUsedKb,
            ramTotalKb: poll.ramTotalKb,
            appFps: poll.appFps?.fps,
            appJankPercent: poll.appFps?.jankPercent,
            appPssKb: poll.appPssKb,
            downloadBps: poll.downloadBytesPerSec,
            uploadBps: poll.uploadBytesPerSec
        ))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    // MARK: - Export

    private func export() {
        guard !samples.isEmpty,
              let folder = state.askSaveFolder(prompt: "Export performance report") else { return }
        let stamp = ScreenCaptureService.stamp()
        do {
            try buildJSON().write(to: folder.appendingPathComponent("performance_\(stamp).json"))
            try Data(buildCSV().utf8).write(to: folder.appendingPathComponent("performance_\(stamp).csv"))
            state.showToast(Toast(
                message: "Exported \(samples.count) samples (JSON + CSV)",
                ok: true,
                revealPath: folder.path
            ))
        } catch {
            state.showToast(Toast(message: "Export failed: \(error.localizedDescription)", ok: false))
        }
    }

    private func buildJSON() throws -> Data {
        struct Report: Codable {
            let device: String?
            let package: String?
            let intervalSeconds: Double
            let samples: [SampleDTO]
        }
        struct SampleDTO: Codable {
            let elapsed: Double
            let totalCpuPercent: Double?
            let cores: [CoreDTO]
            let ramUsedMb: Double?
            let ramTotalMb: Double?
            let appFps: Double?
            let appJankPercent: Double?
            let appPssMb: Double?
            let downloadKBs: Double?
            let uploadKBs: Double?
        }
        struct CoreDTO: Codable {
            let core: Int
            let usagePercent: Double
        }
        let report = Report(
            device: serial,
            package: packageId,
            intervalSeconds: Double(Self.interval.components.seconds),
            samples: samples.map { sample in
                SampleDTO(
                    elapsed: sample.elapsed,
                    totalCpuPercent: sample.totalCpu,
                    cores: sample.perCore.map { CoreDTO(core: $0.core, usagePercent: $0.usagePercent) },
                    ramUsedMb: sample.ramUsedKb.map { Double($0) / 1024.0 },
                    ramTotalMb: sample.ramTotalKb.map { Double($0) / 1024.0 },
                    appFps: sample.appFps,
                    appJankPercent: sample.appJankPercent,
                    appPssMb: sample.appPssKb.map { Double($0) / 1024.0 },
                    downloadKBs: sample.downloadBps.map { $0 / 1024.0 },
                    uploadKBs: sample.uploadBps.map { $0 / 1024.0 }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private func buildCSV() -> String {
        let coreCount = samples.map(\.perCore.count).max() ?? 0
        var header = ["elapsed_s", "total_cpu_pct"]
        header += (0..<coreCount).map { "core\($0)_pct" }
        header += ["ram_used_mb", "download_kbs", "upload_kbs", "app_fps", "app_jank_pct", "app_pss_mb"]
        var rows = [header.joined(separator: ",")]
        for sample in samples {
            let byCore = Dictionary(sample.perCore.map { ($0.core, $0.usagePercent) }, uniquingKeysWith: { first, _ in first })
            var columns = [csv(sample.elapsed), csv(sample.totalCpu)]
            columns += (0..<coreCount).map { csv(byCore[$0]) }
            columns += [
                csv(sample.ramUsedKb.map { Double($0) / 1024.0 }),
                csv(sample.downloadBps.map { $0 / 1024.0 }),
                csv(sample.uploadBps.map { $0 / 1024.0 }),
                csv(sample.appFps),
                csv(sample.appJankPercent),
                csv(sample.appPssKb.map { Double($0) / 1024.0 }),
            ]
            rows.append(columns.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func csv(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? ""
    }
}
