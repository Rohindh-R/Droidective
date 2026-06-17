import ADBKit
import Charts
import SwiftUI

/// Dedicated network throughput monitor: live download/upload speed sampled
/// once a second from `/proc/net/dev`, an auto-scaling chart, session totals,
/// a per-interface breakdown, and JSON/CSV export.
struct NetworkView: View {
    @Environment(AppState.self) private var state

    enum Phase { case idle, recording, paused }

    struct Sample: Identifiable {
        let id = UUID()
        let elapsed: TimeInterval
        let downloadBps: Double
        let uploadBps: Double
    }

    @State private var phase: Phase = .idle
    @State private var samples: [Sample] = []
    @State private var interfaces: [InterfaceSpeed] = []
    @State private var startDate: Date?
    @State private var baselineRx: UInt64?
    @State private var baselineTx: UInt64?
    @State private var sessionRx: UInt64 = 0
    @State private var sessionTx: UInt64 = 0
    @State private var sampler: Task<Void, Never>?

    private static let interval: Duration = .seconds(1)
    private static let chartWindow = 120
    private static let maxSamples = 5000

    private var serial: String? { state.targetSerials.first }
    private var recentSamples: [Sample] { Array(samples.suffix(Self.chartWindow)) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .onChange(of: serial) {
            stop()
            resetSession()
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

            Button { stop() } label: { Image(systemName: "stop.fill") }
                .disabled(phase == .idle)
                .help("Stop recording")

            Button { export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(samples.isEmpty)
                .help("Export the recording as JSON + CSV")

            Spacer()

            Text(statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(phase == .recording ? .primary : .secondary)
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
        let clock = String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        switch phase {
        case .idle: return samples.isEmpty ? "Ready" : "Stopped · \(clock)"
        case .recording: return "Recording · \(clock)"
        case .paused: return "Paused · \(clock)"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if serial == nil {
            ContentUnavailableView(
                "No device connected", systemImage: "iphone.slash",
                description: Text("Connect a device to monitor network throughput.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if samples.isEmpty {
            ContentUnavailableView(
                "Nothing recorded yet", systemImage: "speedometer",
                description: Text("Press Record to start sampling download and upload speed.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    readoutCard
                    chartCard
                    totalsCard
                    interfaceCard
                }
                .padding(14)
            }
        }
    }

    private var readoutCard: some View {
        HStack(spacing: 0) {
            readout("Download", samples.last?.downloadBps ?? 0, "arrow.down", .blue)
            Divider().frame(height: 54)
            readout("Upload", samples.last?.uploadBps ?? 0, "arrow.up", .green)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
                    Text("Per-interface speeds appear while recording.")
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

    private func card(_ title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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

    // MARK: - Recording

    private func toggleRecord() {
        switch phase {
        case .idle:
            resetSession()
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

    private func resetSession() {
        samples = []
        interfaces = []
        baselineRx = nil
        baselineTx = nil
        sessionRx = 0
        sessionTx = 0
        startDate = nil
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
        if baselineRx == nil {
            baselineRx = sample.totalRxBytes
            baselineTx = sample.totalTxBytes
        }
        sessionRx = sample.totalRxBytes &- (baselineRx ?? sample.totalRxBytes)
        sessionTx = sample.totalTxBytes &- (baselineTx ?? sample.totalTxBytes)
        interfaces = sample.interfaces
        let elapsed = Date().timeIntervalSince(startDate ?? Date())
        samples.append(Sample(
            elapsed: elapsed,
            downloadBps: sample.downloadBytesPerSec,
            uploadBps: sample.uploadBytesPerSec
        ))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    // MARK: - Export

    private func export() {
        guard !samples.isEmpty,
              let folder = state.askSaveFolder(prompt: "Export network report") else { return }
        let stamp = ScreenCaptureService.stamp()
        do {
            try buildJSON().write(to: folder.appendingPathComponent("network_\(stamp).json"))
            try Data(buildCSV().utf8).write(to: folder.appendingPathComponent("network_\(stamp).csv"))
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
            samples: samples.map {
                SampleDTO(elapsed: $0.elapsed, downloadKBs: $0.downloadBps / 1024.0, uploadKBs: $0.uploadBps / 1024.0)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private func buildCSV() -> String {
        var rows = ["elapsed_s,download_kbs,upload_kbs"]
        for sample in samples {
            rows.append([
                String(format: "%.2f", sample.elapsed),
                String(format: "%.2f", sample.downloadBps / 1024.0),
                String(format: "%.2f", sample.uploadBps / 1024.0),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
