import ADBKit
import SwiftUI

/// In-app screen mirror: a native scrcpy client renders the device live, in
/// window. The toolbar takes a screenshot (→ annotate in place) or records
/// (→ video editor on stop) without interrupting the live, controllable mirror.
struct ScreenMirrorView: View {
    @Environment(AppState.self) private var state
    @State private var model: MirrorViewModel?

    var body: some View {
        ZStack {
            if let model {
                MirrorStage(model: model)
            } else {
                ContentUnavailableView(
                    "Connect a device to mirror",
                    systemImage: "iphone",
                    description: Text("Plug in or pair a device, then it shows here live."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: state.targetSerials.first) {
            await reconnect(to: state.targetSerials.first)
        }
        .onDisappear {
            let leaving = model
            model = nil
            Task { await leaving?.stop() }
        }
    }

    private func reconnect(to serial: String?) async {
        if let existing = model {
            await existing.stop()
            model = nil
        }
        guard let serial else { return }
        let viewModel = MirrorViewModel(
            adb: state.env.engine.client,
            locator: state.env.engine.locator,
            serial: serial,
            captureFolder: Self.captureFolder())
        model = viewModel
        await viewModel.start()
    }

    private static func captureFolder() -> URL {
        if let path = UserDefaults.standard.string(forKey: ScreenCaptureService.captureFolderDefaultsKey),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return downloads.appendingPathComponent("Droidective", isDirectory: true)
    }
}

private struct MirrorStage: View {
    @Bindable var model: MirrorViewModel

    var body: some View {
        ZStack {
            Color.black
            MirrorVideoView(
                renderer: model.renderer,
                videoSize: model.videoSize,
                onTouch: { action, point in model.touch(action, at: point) },
                onKeycode: { keycode, action in model.key(keycode, action) },
                onText: { model.text($0) })

            switch model.status {
            case .connecting:
                ProgressView("Connecting…").controlSize(.large).tint(.white)
            case let .failed(message):
                statusCard(icon: "exclamationmark.triangle", text: message)
            case .stopped:
                statusCard(icon: "stop.circle", text: "Mirror stopped.")
            case .streaming:
                EmptyView()
            }

            if model.status == .streaming {
                VStack {
                    Spacer()
                    toolbar
                }
            }
        }
        .sheet(isPresented: screenshotPresented) {
            if let image = model.pendingScreenshot {
                ScreenshotEditorView(image: image) { model.pendingScreenshot = nil }
            }
        }
        .sheet(isPresented: recordingPresented) {
            if let url = model.finishedRecording {
                VideoEditorPane(source: .recording(url)) { model.finishedRecording = nil }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            Button { Task { await model.takeScreenshot() } } label: {
                Image(systemName: "camera").font(.title2)
            }
            .help("Screenshot — edit in place")

            Button { Task { await model.toggleRecording() } } label: {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(model.isRecording ? .red : .white)
            }
            .help(model.isRecording ? "Stop recording — opens the editor" : "Record — keep mirroring")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 18)
    }

    private func statusCard(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34))
            Text(text).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var screenshotPresented: Binding<Bool> {
        Binding(
            get: { model.pendingScreenshot != nil },
            set: { if !$0 { model.pendingScreenshot = nil } })
    }

    private var recordingPresented: Binding<Bool> {
        Binding(
            get: { model.finishedRecording != nil },
            set: { if !$0 { model.finishedRecording = nil } })
    }
}
