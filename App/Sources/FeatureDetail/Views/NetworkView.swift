import ADBKit
import Charts
import SwiftUI

/// Dedicated network throughput monitor: live download/upload speed sampled
/// once a second from `/proc/net/dev`, an auto-scaling chart, session totals,
/// a per-interface breakdown, and JSON/CSV export.
struct NetworkView: View {
    @Environment(AppState.self) private var state

    struct Sample: Identifiable {
        let id = UUID()
        let elapsed: TimeInterval
        let downloadBps: Double
        let uploadBps: Double
    }

    /// Live = streaming the view (sampler running, rolling chart). Recording
    /// captures an exportable session on top — you can watch traffic without it.
    @State private var isLive = false
    @State private var isRecording = false
    @State private var liveSamples: [Sample] = []   // rolling window for the chart/readout
    @State private var recorded: [Sample] = []       // the exportable recording
    @State private var interfaces: [InterfaceSpeed] = []
    @State private var liveStart: Date?
    @State private var recordStart: Date?
    @State private var baselineRx: UInt64?
    @State private var baselineTx: UInt64?
    @State private var sessionRx: UInt64 = 0
    @State private var sessionTx: UInt64 = 0
    @State private var sampler: Task<Void, Never>?

    private static let interval: Duration = .seconds(1)
    private static let chartWindow = 120
    private static let maxSamples = 5000

    private var serial: String? { state.targetSerials.first }
    private var recentSamples: [Sample] { Array(liveSamples.suffix(Self.chartWindow)) }

    var body: some View {
        content
            .onAppear { setLive(true) }
            .onChange(of: serial) {
                setLive(false)
                setLive(true)
            }
            .onDisappear {
                setLive(false)
            }
    }

    // MARK: - Live traffic monitor

    /// Live stream (just watch) + an independent Record (capture & export).
    private var monitorCard: some View {
        card("Live traffic", subtitle: statusText, accessory: AnyView(statusDot)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { setLive(!isLive) } label: {
                        Label(isLive ? "Live" : "Paused",
                              systemImage: isLive ? "dot.radiowaves.left.and.right" : "play.fill")
                            .frame(minWidth: 78)
                    }
                    .buttonStyle(.bordered)
                    .tint(isLive ? .blue : .secondary)
                    .disabled(serial == nil)
                    .help(isLive ? "Pause the live view" : "Start watching live traffic")

                    Button { isRecording ? stopRecording() : startRecording() } label: {
                        Label(isRecording ? "Stop" : "Record",
                              systemImage: isRecording ? "stop.fill" : "record.circle")
                            .frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRecording ? .red : .accentColor)
                    .disabled(!isLive)
                    .help(isRecording ? "Stop recording" : "Record a session to export")

                    Spacer()

                    Button { export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(recorded.isEmpty)
                        .help("Export the recording as JSON + CSV")
                }
                if let last = liveSamples.last {
                    HStack(spacing: 0) {
                        readout("Download", last.downloadBps, "arrow.down", .blue)
                        Divider().frame(height: 54)
                        readout("Upload", last.uploadBps, "arrow.up", .green)
                    }
                } else {
                    Text("Watching device-wide download & upload throughput, sampled from /proc/net/dev once a second. Press Record to capture an exportable session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A dot beside the title: red while recording, green while just watching.
    @ViewBuilder
    private var statusDot: some View {
        if isRecording {
            Circle().fill(.red).frame(width: 8, height: 8)
        } else if isLive {
            Circle().fill(.green).frame(width: 8, height: 8)
        }
    }

    private var statusText: String {
        if isRecording {
            let elapsed = recorded.last?.elapsed ?? 0
            return "Recording · " + String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        }
        return isLive ? "Live" : "Paused"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if serial == nil {
            ContentUnavailableView(
                "No device connected", systemImage: "iphone.slash",
                description: Text("Connect a device to monitor its network throughput.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monitorCard
                    if !liveSamples.isEmpty {
                        chartCard
                        interfaceCard
                    }
                    if isRecording || !recorded.isEmpty {
                        totalsCard
                    }
                }
                .padding(16)
            }
        }
    }

    private func readout(_ title: String, _ bytesPerSec: Double, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(speed(bytesPerSec))
                .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private var chartCard: some View {
        card("Throughput", subtitle: "KB/s") {
            Chart(recentSamples) { sample in
                LineMark(
                    x: .value("Time", sample.elapsed),
                    y: .value("KB/s", sample.downloadBps / 1024.0)
                )
                .foregroundStyle(by: .value("Series", "Download"))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.elapsed),
                    y: .value("KB/s", sample.uploadBps / 1024.0)
                )
                .foregroundStyle(by: .value("Series", "Upload"))
                .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.green])
            .chartXAxisLabel("seconds")
            .chartLegend(position: .bottom, spacing: 6)
            .frame(height: 170)
        }
    }

    private var totalsCard: some View {
        card("This session", subtitle: statusText) {
            HStack(spacing: 0) {
                total("Downloaded", sessionRx, .blue)
                Divider().frame(height: 36)
                total("Uploaded", sessionTx, .green)
            }
        }
    }

    private func total(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(bytesLabel(bytes))
                .font(.title3.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var interfaceCard: some View {
        card("Interfaces", subtitle: "\(interfaces.count)") {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("Interface").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Download").frame(width: 110, alignment: .trailing)
                    Text("Upload").frame(width: 110, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                if interfaces.isEmpty {
                    Text("Per-interface speeds appear while live.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ForEach(interfaces) { interface in
                        HStack(spacing: 8) {
                            Text(interface.name)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(speed(interface.downloadBytesPerSec))
                                .font(.caption.monospacedDigit())
                                .frame(width: 110, alignment: .trailing)
                            Text(speed(interface.uploadBytesPerSec))
                                .font(.caption.monospacedDigit())
                                .frame(width: 110, alignment: .trailing)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func card(
        _ title: String, subtitle: String, accessory: AnyView? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(.headline)
                if let accessory { accessory }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4)))
    }

    // MARK: - Formatting

    private func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 KB/s" }
        return bytesPerSec >= 1_048_576
            ? String(format: "%.2f MB/s", bytesPerSec / 1_048_576)
            : String(format: "%.0f KB/s", bytesPerSec / 1024)
    }

    private func bytesLabel(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    // MARK: - Live / recording

    /// Toggle the live stream. Turning it off also stops any recording.
    private func setLive(_ on: Bool) {
        if on {
            guard serial != nil, !isLive else { return }
            isLive = true
            liveStart = Date()
            liveSamples = []
            interfaces = []
            launchSampler()
        } else {
            stopRecording()
            isLive = false
            sampler?.cancel()
            sampler = nil
        }
    }

    /// Start capturing an exportable session on top of the live stream.
    private func startRecording() {
        guard isLive else { return }
        isRecording = true
        recordStart = Date()
        recorded = []
        baselineRx = nil
        baselineTx = nil
        sessionRx = 0
        sessionTx = 0
        state.recordingActive = true
    }

    private func stopRecording() {
        isRecording = false
        state.recordingActive = false
    }

    private func launchSampler() {
        guard let serial else { return }
        sampler?.cancel()
        sampler = Task { @MainActor in
            await state.env.engine.networkSpeed.reset()
            while !Task.isCancelled {
                let sample = await state.env.engine.networkSpeed.poll(serial: serial)
                if Task.isCancelled { break }
                if let sample { append(sample) }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func append(_ sample: NetSample) {
        interfaces = sample.interfaces

        let liveElapsed = Date().timeIntervalSince(liveStart ?? Date())
        liveSamples.append(Sample(
            elapsed: liveElapsed,
            downloadBps: sample.downloadBytesPerSec,
            uploadBps: sample.uploadBytesPerSec
        ))
        if liveSamples.count > Self.chartWindow * 2 {
            liveSamples.removeFirst(liveSamples.count - Self.chartWindow * 2)
        }

        guard isRecording else { return }
        if baselineRx == nil {
            baselineRx = sample.totalRxBytes
            baselineTx = sample.totalTxBytes
        }
        sessionRx = sample.totalRxBytes &- (baselineRx ?? sample.totalRxBytes)
        sessionTx = sample.totalTxBytes &- (baselineTx ?? sample.totalTxBytes)
        let recElapsed = Date().timeIntervalSince(recordStart ?? Date())
        recorded.append(Sample(
            elapsed: recElapsed,
            downloadBps: sample.downloadBytesPerSec,
            uploadBps: sample.uploadBytesPerSec
        ))
        if recorded.count > Self.maxSamples {
            recorded.removeFirst(recorded.count - Self.maxSamples)
        }
    }

    // MARK: - Export

    private func export() {
        guard !recorded.isEmpty,
              let folder = state.askSaveFolder(prompt: "Export network report") else { return }
        let stamp = ScreenCaptureService.stamp()
        do {
            try buildJSON().write(to: folder.appendingPathComponent("network_\(stamp).json"))
            try Data(buildCSV().utf8).write(to: folder.appendingPathComponent("network_\(stamp).csv"))
            state.showToast(Toast(
                message: "Exported \(recorded.count) samples (JSON + CSV)",
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
            let intervalSeconds: Double
            let sessionDownloadedBytes: UInt64
            let sessionUploadedBytes: UInt64
            let samples: [SampleDTO]
        }
        struct SampleDTO: Codable {
            let elapsed: Double
            let downloadKBs: Double
            let uploadKBs: Double
        }
        let report = Report(
            device: serial,
            intervalSeconds: Double(Self.interval.components.seconds),
            sessionDownloadedBytes: sessionRx,
            sessionUploadedBytes: sessionTx,
            samples: recorded.map {
                SampleDTO(elapsed: $0.elapsed, downloadKBs: $0.downloadBps / 1024.0, uploadKBs: $0.uploadBps / 1024.0)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private func buildCSV() -> String {
        var rows = ["elapsed_s,download_kbs,upload_kbs"]
        for sample in recorded {
            rows.append([
                String(format: "%.2f", sample.elapsed),
                String(format: "%.2f", sample.downloadBps / 1024.0),
                String(format: "%.2f", sample.uploadBps / 1024.0),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

