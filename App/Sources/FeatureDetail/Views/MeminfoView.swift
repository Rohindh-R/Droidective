import ADBKit
import Charts
import SwiftUI

/// Live memory usage for the selected bundle (2s polling) with a Total-PSS graph.
struct MeminfoView: View {
    @Environment(AppState.self) private var state
    @State private var info: MemInfo?
    @State private var history: [MemSample] = []
    @State private var started: Date?
    @State private var selectedElapsed: Double?

    /// One Total-PSS reading on the timeline.
    private struct MemSample: Identifiable {
        let id = UUID()
        let elapsed: Double
        let pssKb: Int
    }

    /// ~3 minutes of 2s samples.
    private static let window = 90

    var body: some View {
        Group {
            if state.selectedBundle == nil {
                ContentUnavailableView(
                    "No bundle selected", systemImage: "memorychip",
                    description: Text("Select a bundle to watch its memory usage.")
                )
            } else if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to read memory usage.")
                )
            } else if let info {
                if info.running {
                    details(info)
                } else {
                    ContentUnavailableView(
                        "App not running", systemImage: "memorychip",
                        description: Text("Open the app on the device to see live memory.")
                    )
                }
            } else {
                ProgressView("Reading memory…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(state.selectedBundleId ?? "")|\(state.targetSerials.first ?? "")") {
            await poll()
        }
    }

    private func details(_ info: MemInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(info)
                graphCard
                if !info.summary.isEmpty {
                    summaryCard(info)
                }
                Text("Refreshes every 2 seconds.")
                    .font(.footnote)
                    .foregroundStyle(.textFaint)
            }
            .centeredColumn(maxWidth: 640)
            .padding(20)
        }
    }

    private func header(_ info: MemInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            stat("Total PSS", formatKb(info.totalPssKb), big: true)
            if let peak = history.map(\.pssKb).max() {
                stat("Peak", formatKb(peak))
            }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(.textMuted)
            Text(value)
                .font(big ? .system(.largeTitle, design: .rounded).weight(.semibold)
                          : .system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit()
        }
    }

    private var graphCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Total PSS over time").font(.headline)
                Text("MB").font(.caption).foregroundStyle(.textMuted)
                Spacer()
            }
            chart
                .frame(height: 200)
                .clipped()
                .overlay {
                    if history.count < 2 {
                        Text("Collecting samples…")
                            .font(.callout).foregroundStyle(.textMuted)
                    }
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.borderSubtle, lineWidth: 1))
    }

    private var chart: some View {
        let domain = yDomain
        return Chart(history) { sample in
            // Fill from the domain floor (not the implicit y=0 baseline, which
            // sits far below this zoomed domain and would bleed past the plot).
            AreaMark(
                x: .value("Time", sample.elapsed),
                yStart: .value("MB", domain.lowerBound),
                yEnd: .value("MB", mb(sample.pssKb))
            )
            .foregroundStyle(.linearGradient(
                colors: [.brandAccent.opacity(0.28), .brandAccent.opacity(0.02)],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", sample.elapsed),
                y: .value("MB", mb(sample.pssKb))
            )
            .foregroundStyle(.brandAccent)
            .interpolationMethod(.monotone)

            if let selected = selectedSample {
                RuleMark(x: .value("Time", selected.elapsed))
                    .foregroundStyle(Color.textMuted.opacity(0.4))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        Text("\(Int(selected.elapsed))s · \(formatKb(selected.pssKb))")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXSelection(value: $selectedElapsed)
        .chartXAxisLabel("seconds")
        .animation(.easeInOut(duration: 0.3), value: domain)
    }

    private func summaryCard(_ info: MemInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            ForEach(info.summary, id: \.key) { row in
                GridRow {
                    Text(row.key).foregroundStyle(.textMuted)
                    Text(formatKb(Int(row.value))).monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.borderSubtle, lineWidth: 1))
    }

    /// Y-axis range that tracks the visible samples — it zooms in on the live
    /// min/max (with 25% headroom) so small fluctuations are visible, and slides
    /// up or down as usage changes. Bounds snap to 8 MB steps so minor jitter
    /// doesn't constantly rescale the axis.
    private var yDomain: ClosedRange<Double> {
        let values = history.map { mb($0.pssKb) }
        guard let lo = values.min(), let hi = values.max() else { return 0...64 }
        let step = 8.0
        let pad = max(step / 2, (hi - lo) * 0.25)
        let low = max(0, ((lo - pad) / step).rounded(.down) * step)
        let high = max(low + step, ((hi + pad) / step).rounded(.up) * step)
        return low...high
    }

    private var selectedSample: MemSample? {
        guard let selectedElapsed else { return nil }
        return history.min { abs($0.elapsed - selectedElapsed) < abs($1.elapsed - selectedElapsed) }
    }

    private func mb(_ kb: Int) -> Double { Double(kb) / 1024.0 }

    private func formatKb(_ kb: Int?) -> String {
        guard let kb else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    private func poll() async {
        info = nil
        history = []
        started = nil
        selectedElapsed = nil
        guard let serial = state.targetSerials.first,
              let packageId = state.selectedBundle?.packageId else { return }
        // The first read is user-initiated so it lands in the Recent log; the
        // 2s polling that follows stays out of the log (background).
        let first = await CommandLog.userInitiated(feature: "meminfo") {
            try? await state.env.engine.inspection.getMemInfo(serial: serial, packageId: packageId)
        }
        guard !Task.isCancelled else { return }
        record(first)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let result = try? await state.env.engine.inspection.getMemInfo(serial: serial, packageId: packageId)
            guard !Task.isCancelled else { return }
            record(result)
        }
    }

    /// Store the latest reading and, while the app is running, append a graph
    /// point keyed on real elapsed time (so a slow poll doesn't distort it).
    private func record(_ result: MemInfo?) {
        info = result
        guard let result, result.running, let pss = result.totalPssKb else { return }
        let now = Date()
        let start = started ?? now
        if started == nil { started = start }
        history.append(MemSample(elapsed: now.timeIntervalSince(start), pssKb: pss))
        if history.count > Self.window {
            history.removeFirst(history.count - Self.window)
        }
    }
}
