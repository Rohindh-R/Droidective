import ADBKit
import SwiftUI

/// In-app screen mirror: a native scrcpy client renders the device live, in
/// window. The toolbar takes a screenshot (→ annotate in place) or records
/// (→ video editor on stop) without interrupting the live, controllable mirror.
struct ScreenMirrorView: View {
    @Environment(AppState.self) private var state
    @Environment(\.tabFeatureID) private var tabFeatureID
    @Environment(\.tabIsActive) private var tabIsActive
    @State private var model: MirrorViewModel?
    /// Identifies this view's leave guard so a stale clear can't wipe another's.
    @State private var exitGuardID = UUID()

    var body: some View {
        ZStack {
            if let model {
                // After Edit, take over the whole pane with the editor (full
                // screen, not a sheet) so its tools are fully usable; closing it
                // returns to the live mirror.
                if let url = model.finishedRecording {
                    VideoEditorPane(source: .recording(url)) {
                        try? FileManager.default.removeItem(at: url)
                        model.finishedRecording = nil
                    }
                    .id(url)
                } else if let image = model.editingScreenshot {
                    ScreenshotEditorView(image: image) { model.editingScreenshot = nil }
                } else {
                    MirrorStage(model: model)
                }
            } else {
                ContentUnavailableView(
                    "Connect a device to mirror",
                    systemImage: "iphone",
                    description: Text("Plug in or pair a device, then it shows here live."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .recordingDecision(url: pendingRecording) { url in model?.finishedRecording = url }
        .imageDecision(image: pendingScreenshot) { image in model?.editingScreenshot = image }
        .task(id: state.targetSerials.first) {
            // Only stream while this tab is on screen; a hidden mirror is heavy
            // video encode for nothing. (Returning re-keys via tabIsActive below.)
            if tabIsActive { await reconnect(to: state.targetSerials.first) }
        }
        .onChange(of: tabIsActive) { _, active in
            if active {
                if model == nil { Task { await reconnect(to: state.targetSerials.first) } }
            } else if model?.isRecording != true {
                // Pause the live mirror while hidden — unless it's recording,
                // which must keep capturing.
                let leaving = model
                model = nil
                Task { await leaving?.stop() }
            }
        }
        .onChange(of: model?.recordingError) { _, message in
            guard let message else { return }
            state.showToast(Toast(message: message, ok: false))
            model?.recordingError = nil
        }
        .onChange(of: model?.isRecording) { _, recording in
            if recording == true {
                state.setExitGuard(.init(
                    id: exitGuardID, featureID: tabFeatureID, style: .recording,
                    title: "Recording in progress",
                    message: "Leaving will stop the screen recording. Save it first, or discard it."))
            } else {
                state.clearExitGuard(exitGuardID)
            }
        }
        .onChange(of: state.pendingExit?.saving) { _, saving in
            if saving == true, model?.isRecording == true, state.pendingExitConcerns(tabFeatureID) {
                Task { await saveRecordingForLeave() }
            }
        }
        .onDisappear {
            state.clearExitGuard(exitGuardID)
            let leaving = model
            model = nil
            Task { await leaving?.stop() }
        }
    }

    /// "Stop & save" from the leave prompt: finalize the in-mirror recording into
    /// the capture folder (skipping the Discard/Save/Edit sheet), then proceed.
    private func saveRecordingForLeave() async {
        guard let model else { state.finishExitSave(); return }
        if let temp = await model.finishRecordingForLeave() {
            do {
                let dir = try ScreenCaptureService.ensureCaptureDir()
                let dest = dir.appendingPathComponent("recording_\(ScreenCaptureService.stamp()).mp4")
                try FileManager.default.moveItem(at: temp, to: dest)
                state.showToast(Toast(message: "Recording saved", ok: true, revealPath: dest.path))
            } catch {
                state.showToast(Toast(message: "Couldn’t save recording: \(error.localizedDescription)", ok: false))
            }
        }
        state.finishExitSave()
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
            serial: serial)
        model = viewModel
        await viewModel.start()
    }

    private var pendingRecording: Binding<URL?> {
        Binding(get: { model?.pendingRecording }, set: { model?.pendingRecording = $0 })
    }

    private var pendingScreenshot: Binding<NSImage?> {
        Binding(get: { model?.pendingScreenshot }, set: { model?.pendingScreenshot = $0 })
    }
}

private struct MirrorStage: View {
    @Bindable var model: MirrorViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MirrorVideoView(
                    renderer: model.renderer,
                    videoSize: model.videoSize,
                    onTouch: { action, point in model.touch(action, at: point) },
                    onKeycode: { keycode, action in model.key(keycode, action) },
                    onText: { model.text($0) },
                    onPaste: { model.pasteToDevice() },
                    onCopy: { model.copyFromDevice(cut: false) },
                    onCut: { model.copyFromDevice(cut: true) })

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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlBar
        }
    }

    /// Controls below the mirror: device nav keys, then screenshot + record.
    private var controlBar: some View {
        HStack(spacing: 16) {
            navButton("chevron.backward", help: "Back") { model.tapKey(4) }
            navButton("circle", help: "Home") { model.tapKey(3) }
            navButton("square", help: "Recent apps") { model.tapKey(187) }

            Divider().frame(height: 22)

            navButton("camera", help: "Screenshot — edit in place") {
                Task { await model.takeScreenshot() }
            }

            if model.isRecording {
                navButton(
                    model.isPaused ? "play.fill" : "pause.fill",
                    help: model.isPaused ? "Resume recording" : "Pause recording"
                ) {
                    Task { model.isPaused ? await model.resumeRecording() : await model.pauseRecording() }
                }
                navButton("stop.circle.fill", tint: .red, help: "Stop recording") {
                    Task { await model.stopRecording() }
                }
            } else {
                navButton("record.circle", help: "Record — keep mirroring") {
                    Task { await model.startRecording() }
                }
            }

            Divider().frame(height: 22)

            // Device volume (one step per tap) + one-shot mute/unmute.
            navButton("speaker.wave.1.fill", help: "Volume down") { model.tapKey(25) }
            navButton("speaker.wave.3.fill", help: "Volume up") { model.tapKey(24) }
            navButton("speaker.slash.fill", help: "Mute / unmute") { model.tapKey(164) }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .disabled(model.status != .streaming)
    }

    private func navButton(
        _ systemImage: String, tint: Color? = nil, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
}

