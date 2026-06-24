import ADBKit
import Foundation
import SwiftUI

/// Record the device screen via the in-app scrcpy client (bundled server, no
/// separate install, audio on Android 11+). The Record button and status sit up
/// top; tuning lives in a collapsed Advanced drop-down. Stopping opens the clip
/// in the video editor.
struct ScreenRecordView: View {
    @Environment(AppState.self) private var state
    @State private var recorder: ScreenRecorder?
    @State private var isRecording = false
    @State private var isPaused = false
    @State private var isStarting = false
    @State private var isStopping = false
    @State private var isBusy = false
    @State private var startedAt: Date?
    @State private var recordedURL: URL?
    /// A finished recording awaiting the Discard/Save/Edit choice.
    @State private var decisionURL: URL?
    @State private var showAdvanced = false
    @State private var limitTask: Task<Void, Never>?

    @AppStorage("recMaxSize") private var maxSize = 0
    @AppStorage("recBitRate") private var bitRateMbps = 0
    @AppStorage("recMaxFps") private var maxFps = 0
    @AppStorage("recCaptureAudio") private var captureAudio = true
    @AppStorage("recTimeLimit") private var timeLimit = 0

    private var recordOptions: ScreenRecordOptions {
        ScreenRecordOptions(
            maxSize: maxSize, bitRateMbps: bitRateMbps, maxFps: maxFps,
            captureAudio: captureAudio, timeLimitSeconds: timeLimit
        )
    }

    var body: some View {
        Group {
            if let url = recordedURL {
                VideoEditorPane(source: .recording(url)) {
                    try? FileManager.default.removeItem(at: url)
                    recordedURL = nil
                }
                .id(url)
            } else {
                recordControls
            }
        }
        .recordingDecision(url: $decisionURL) { recordedURL = $0 }
        .onDisappear {
            limitTask?.cancel()
            if isRecording, let recorder { Task { await recorder.abort() } }
            if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    private var recordControls: some View {
        VStack(spacing: 28) {
            hero
            optionsCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // MARK: centered record control

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red.opacity(0.15) : Color.brandAccent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "video.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(isRecording ? .red : .brandAccent)
                    .symbolEffect(.pulse, isActive: isRecording)
            }

            VStack(spacing: 4) {
                if isRecording, let startedAt {
                    Text(startedAt, style: .timer)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    Text(isPaused ? "Paused" : "Recording…")
                        .font(.subheadline)
                        .foregroundStyle(isPaused ? Color.secondary : Color.red)
                } else {
                    Text("Ready to record").font(.title2.weight(.semibold))
                }
            }

            recordControlButtons
            hints
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder private var recordControlButtons: some View {
        if isRecording {
            HStack(spacing: 12) {
                Button {
                    Task { isPaused ? await resume() : await pause() }
                } label: {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 104)
                }
                .controlSize(.large)
                .disabled(isBusy)

                Button { Task { await stop() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(width: 104)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .disabled(isStopping)
            }
        } else {
            Button { Task { await start() } } label: {
                Label(isStarting ? "Starting…" : "Record", systemImage: "record.circle")
                    .frame(width: 220)
            }
            .buttonStyle(.borderedProminent).tint(.brandAccent).controlSize(.large)
            .disabled(isStarting || state.targetSerials.isEmpty)
        }
    }

    @ViewBuilder private var hints: some View {
        if state.targetSerials.isEmpty {
            Text("Connect a device to record.").font(.footnote).foregroundStyle(.textMuted)
        }
    }

    // MARK: options (basic outside, the rest under Advanced)

    private var optionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("Resolution") { resolutionPicker }
                SwitchRow("Capture audio (Android 11+)", isOn: $captureAudio)
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        labeledRow("Bit rate") { bitRatePicker }
                        labeledRow("Max FPS") { fpsPicker }
                        labeledRow("Time limit") { timeLimitPicker }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("Advanced options").font(.callout.weight(.medium))
                }
            }
            .padding(10)
        }
        .frame(maxWidth: 420)
        .disabled(isRecording)
    }

    private func labeledRow(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }

    private var resolutionPicker: some View {
        Picker("", selection: $maxSize) {
            Text("Device").tag(0)
            Text("1920 px").tag(1920)
            Text("1280 px").tag(1280)
            Text("1024 px").tag(1024)
            Text("800 px").tag(800)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private var bitRatePicker: some View {
        Picker("", selection: $bitRateMbps) {
            Text("Default").tag(0)
            Text("2 Mbps").tag(2)
            Text("4 Mbps").tag(4)
            Text("8 Mbps").tag(8)
            Text("16 Mbps").tag(16)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private var fpsPicker: some View {
        Picker("", selection: $maxFps) {
            Text("Unlimited").tag(0)
            Text("30").tag(30)
            Text("60").tag(60)
            Text("120").tag(120)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private var timeLimitPicker: some View {
        Picker("", selection: $timeLimit) {
            Text("Unlimited").tag(0)
            Text("1 min").tag(60)
            Text("3 min").tag(180)
            Text("5 min").tag(300)
            Text("10 min").tag(600)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func start() async {
        guard let serial = state.targetSerials.first, !isStarting else { return }
        guard let server = BundledTools.scrcpyServer() else {
            state.showToast(Toast(message: "Bundled scrcpy server is missing from the app.", ok: false))
            return
        }
        isStarting = true
        let recorder = ScreenRecorder(
            client: state.env.client, server: server, ffmpegPath: BundledTools.ffmpegPath())
        let options = recordOptions
        do {
            try await recorder.start(serial: serial, options: options)
            self.recorder = recorder
            isRecording = true
            isPaused = false
            startedAt = Date()
            scheduleTimeLimit(options.timeLimitSeconds)
        } catch {
            state.showToast(Toast(message: error.localizedDescription, ok: false))
        }
        isStarting = false
    }

    private func pause() async {
        guard let recorder, !isBusy, !isPaused else { return }
        isBusy = true
        await recorder.pause()
        isPaused = true
        isBusy = false
    }

    private func resume() async {
        guard let recorder, !isBusy, isPaused else { return }
        isBusy = true
        do {
            try await recorder.resume()
            isPaused = false
        } catch {
            state.showToast(Toast(message: error.localizedDescription, ok: false))
        }
        isBusy = false
    }

    /// The server has no time-limit knob, so the UI stops the recording after the
    /// chosen duration (0 = unlimited). Paused time still counts toward the limit.
    private func scheduleTimeLimit(_ seconds: Int) {
        limitTask?.cancel()
        guard seconds > 0 else { return }
        limitTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, isRecording { await stop() }
        }
    }

    private func stop() async {
        guard let recorder, !isStopping else { return }
        limitTask?.cancel()
        limitTask = nil
        isStopping = true
        do {
            let url = try await state.withOperation("Finishing recording…") {
                try await recorder.stop()
            }
            decisionURL = url
        } catch {
            state.showToast(Toast(message: error.localizedDescription, ok: false))
        }
        isRecording = false
        isPaused = false
        isStopping = false
        startedAt = nil
        self.recorder = nil
    }
}
