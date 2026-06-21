import ADBKit
import SwiftUI

/// Record the device screen, auto-pull on stop, optional GIF conversion, with
/// common screenrecord options.
struct ScreenRecordView: View {
    @Environment(AppState.self) private var state
    @State private var recorder: ScreenRecorder?
    @State private var isRecording = false
    @State private var isStarting = false
    @State private var isSaving = false
    @State private var startedAt: Date?

    @AppStorage("recSize") private var size = ""
    @AppStorage("recBitRate") private var bitRateMbps = 8
    @AppStorage("recTimeLimit") private var timeLimit = 0
    @AppStorage("recRotate") private var rotate = false
    @AppStorage("recBugreport") private var bugreport = false
    @AppStorage("recMakeGif") private var makeGif = false

    private var recordOptions: ScreenRecordOptions {
        let dimensions = size.split(separator: "x").compactMap { Int($0) }
        let (width, height) = dimensions.count == 2 ? (dimensions[0], dimensions[1]) : (0, 0)
        return ScreenRecordOptions(
            bitRateMbps: bitRateMbps, sizeWidth: width, sizeHeight: height,
            timeLimitSeconds: timeLimit, rotate: rotate, bugreport: bugreport
        )
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "video")
                        .font(.title2)
                        .foregroundStyle(isRecording ? .red : .textMuted)
                        .symbolEffect(.pulse, isActive: isRecording)
                    if isRecording, let startedAt {
                        Text(startedAt, style: .timer)
                            .font(.system(.title3, design: .monospaced))
                    } else {
                        Text("Ready to record").foregroundStyle(.textMuted)
                    }
                    Spacer()
                }
            }

            Section("Options") {
                Picker("Resolution", selection: $size) {
                    Text("Device default").tag("")
                    Text("1280 × 720").tag("1280x720")
                    Text("854 × 480").tag("854x480")
                    Text("640 × 360").tag("640x360")
                }
                Picker("Bit rate", selection: $bitRateMbps) {
                    Text("4 Mbps").tag(4)
                    Text("8 Mbps").tag(8)
                    Text("12 Mbps").tag(12)
                    Text("16 Mbps").tag(16)
                    Text("20 Mbps").tag(20)
                }
                Picker("Time limit", selection: $timeLimit) {
                    Text("Max (~3 min)").tag(0)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                    Text("120s").tag(120)
                }
                SwitchRow("Rotate 90°", isOn: $rotate)
                SwitchRow("Timestamp overlay (bug report)", isOn: $bugreport)
                SwitchRow("Convert to GIF when done (needs ffmpeg)", isOn: $makeGif)
            }
            .disabled(isRecording)

            Section {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Label(
                        isSaving ? "Saving…" : (isRecording ? "Stop & Save" : "Record"),
                        systemImage: isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .brandAccent)
                .controlSize(.large)
                .disabled(isStarting || isSaving || state.targetSerials.isEmpty)

                Text("screenrecord has no audio and stops on rotation.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .centeredColumn()
        .onDisappear {
            if isRecording {
                let recorder = recorder
                Task { await recorder?.abort() }
            }
        }
    }

    private func start() {
        guard let serial = state.targetSerials.first, !isStarting else { return }
        isStarting = true
        let recorder = ScreenRecorder(client: state.env.client)
        self.recorder = recorder
        let options = recordOptions
        Task {
            do {
                try await recorder.start(serial: serial, options: options)
                isRecording = true
                startedAt = Date()
            } catch {
                state.showToast(Toast(message: error.localizedDescription, ok: false))
                self.recorder = nil
            }
            isStarting = false
        }
    }

    private func stop() {
        guard let recorder else { return }
        isSaving = true
        Task {
            let suggested = await recorder.suggestedFileName ?? "screen-recording.mp4"
            guard let dest = state.askSaveLocation(suggestedName: suggested) else {
                // Keep recording — the user only cancelled the save dialog.
                isSaving = false
                return
            }
            await CommandLog.userInitiated(feature: "screen-record") {
                do {
                    let output = try await state.withOperation(
                        makeGif ? "Saving recording + GIF…" : "Saving recording…"
                    ) {
                        try await recorder.stop(makeGif: makeGif, to: dest)
                    }
                    let saved = output.gifPath ?? output.localPath
                    state.showToast(Toast(message: "Recording saved", ok: true, revealPath: saved.path))
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
            isRecording = false
            isSaving = false
            startedAt = nil
            self.recorder = nil
        }
    }
}
