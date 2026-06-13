import ADBKit
import SwiftUI

/// Live memory usage for the selected bundle (2s polling).
struct MeminfoView: View {
    @Environment(AppState.self) private var state
    @State private var info: MemInfo?

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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(state.selectedBundleId ?? "")|\(state.targetSerials.first ?? "")") {
            await poll()
        }
    }

    private func details(_ info: MemInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total PSS")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(formatKb(info.totalPssKb))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(info.summary, id: \.key) { row in
                    GridRow {
                        Text(row.key).foregroundStyle(.secondary)
                        Text(formatKb(Int(row.value))).monospacedDigit()
                    }
                }
            }

            Text("Refreshes every 2 seconds.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func formatKb(_ kb: Int?) -> String {
        guard let kb else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    private func poll() async {
        info = nil
        guard let serial = state.targetSerials.first,
              let packageId = state.selectedBundle?.packageId else { return }
        while !Task.isCancelled {
            let result = try? await state.env.engine.inspection.getMemInfo(serial: serial, packageId: packageId)
            guard !Task.isCancelled else { return }
            info = result
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
