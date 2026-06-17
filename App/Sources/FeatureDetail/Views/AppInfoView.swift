import ADBKit
import SwiftUI

/// Version, SDK, install dates, APK size — and a one-click APK pull.
struct AppInfoView: View {
    @Environment(AppState.self) private var state
    @State private var info: AppInfo?
    @State private var pulling = false

    var body: some View {
        Group {
            if state.selectedBundle == nil {
                ContentUnavailableView(
                    "No bundle selected", systemImage: "shippingbox",
                    description: Text("Select a bundle to see its app info.")
                )
            } else if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to read app info.")
                )
            } else if let info {
                if info.installed {
                    details(info)
                } else {
                    ContentUnavailableView(
                        "Not installed", systemImage: "shippingbox",
                        description: Text("\(state.selectedBundle?.packageId ?? "The app") isn't installed on this device.")
                    )
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(state.selectedBundleId ?? "")|\(state.targetSerials.first ?? "")") {
            await load()
        }
    }

    private func details(_ info: AppInfo) -> some View {
        Form {
            LabeledContent("Version", value: info.versionName)
            LabeledContent("Version Code", value: info.versionCode)
            LabeledContent("Target SDK", value: info.targetSdk)
            LabeledContent("Min SDK", value: info.minSdk)
            LabeledContent("First Install", value: info.firstInstall)
            LabeledContent("Last Update", value: info.lastUpdate)
            if let size = info.apkSizeBytes {
                LabeledContent("APK Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }

            Button {
                pullApk()
            } label: {
                Label(pulling ? "Pulling…" : "Pull APK", systemImage: "arrow.down.circle")
            }
            .disabled(pulling)
        }
        .formStyle(.grouped)
    }

    private func load() async {
        info = nil
        guard let serial = state.targetSerials.first,
              let packageId = state.selectedBundle?.packageId else { return }
        let result = await CommandLog.userInitiated(feature: "app-info") {
            (try? await state.env.engine.inspection.getAppInfo(serial: serial, packageId: packageId)) ?? .notInstalled
        }
        guard !Task.isCancelled else { return }
        info = result
    }

    private func pullApk() {
        guard let serial = state.targetSerials.first,
              let packageId = state.selectedBundle?.packageId else { return }
        guard let dest = state.askSaveLocation(suggestedName: "\(packageId).apk") else { return }
        pulling = true
        Task {
            await CommandLog.userInitiated(feature: "app-info") {
                do {
                    let saved = try await state.withFileProgress(
                        "Pulling APK…", destination: dest, expectedBytes: info?.apkSizeBytes
                    ) {
                        try await state.env.engine.inspection.pullApk(serial: serial, packageId: packageId, to: dest)
                    }
                    state.showToast(Toast(message: "APK saved", ok: true, revealPath: saved.path))
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            pulling = false
        }
    }
}
