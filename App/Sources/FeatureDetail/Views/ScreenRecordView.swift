import ADBKit
import SwiftUI

/// Record the device screen, auto-pull on stop, optional GIF conversion.
struct ScreenRecordView: View {
    @Environment(AppState.self) private var state
    @State private var recorder: ScreenRecorder?
    @State private var isRecording = false
    @State private var isStarting = false
    @State private var isSaving = false
    @State private var makeGif = false
    @State private var startedAt: Date?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video")
                .font(.system(size: 36))
                .foregroundStyle(isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: isRecording)

            if isRecording, let startedAt {
                Text(startedAt, style: .timer)
                    .font(.system(.title2, design: .monospaced))
            }

            Toggle("Convert to GIF when done (needs ffmpeg)", isOn: $makeGif)
                .disabled(isRecording)

            Button {
                isRecording ? stop() : start()
            } label: {
                Label(
                    isSaving ? "Saving…" : (isRecording ? "Stop & Save" : "Record"),
                    systemImage: isRecording ? "stop.fill" : "record.circle"
                )
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(isStarting || isSaving || state.targetSerials.isEmpty)

            Text("screenrecord caps at ~3 minutes, has no audio, and stops on rotation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
        Task {
            do {
                try await recorder.start(serial: serial)
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
            await CommandLog.$isUserInitiated.withValue(true) {
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
