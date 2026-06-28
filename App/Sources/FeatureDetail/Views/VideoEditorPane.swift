import ADBKit
import AVFoundation
import Combine
import SwiftUI

/// What the editor is working on. A recording is a temp file the caller deletes
/// on close; a user-opened file is never deleted.
enum VideoSource: Equatable {
    case recording(URL)
    case file(URL)

    var url: URL {
        switch self {
        case .recording(let url), .file(let url): return url
        }
    }
}

/// All reversible edits, snapshotted for undo/redo. Crop mode is a UI state, not
/// an edit, so it lives outside this.
struct EditState: Equatable {
    var trimStart: Double?
    var trimEnd: Double?
    var rotation = 0
    var flipH = false
    var flipV = false
    var crop: CropRect?
    var speed = 1.0
    var mute = false
    var compression: CompressionLevel = .none
    var format: VideoFormat = .mp4
}

/// A read-only crop indicator: dims outside the normalized crop region and
/// outlines it, so an applied crop is previewed without clipping the player or
/// its transport controls. The actual crop is applied at export via ffmpeg.
struct CropIndicator: View {
    let crop: CropRect

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(
                x: crop.x * size.width, y: crop.y * size.height,
                width: crop.width * size.width, height: crop.height * size.height)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.4)))
            context.blendMode = .destinationOut
            context.fill(Path(rect), with: .color(.black))
            context.blendMode = .normal
            context.stroke(Path(rect), with: .color(.brandAccent), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// A pill toggle with an obvious filled (on) vs. outlined (off) state.
struct EditToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(configuration.isOn ? Color.brandAccent : Color.primary.opacity(0.07))
                .foregroundStyle(
                    configuration.isOn
                        ? Color.brandAccent.contrastingForeground(for: colorScheme)
                        : Color.primary
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(configuration.isOn ? Color.clear : Color.primary.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
    }
}

/// The shared video editor. Rotate/flip/crop are previewed with SwiftUI view
/// transforms (so they reflect instantly) and exported through ffmpeg; trimming
/// uses the native player UI. Nothing is written until Export.
struct VideoEditorPane: View {
    @Environment(AppState.self) private var state
    let source: VideoSource
    let onClose: () -> Void

    @State private var player: AVPlayer
    @State private var asset: AVURLAsset
    @State private var trimmer = VideoTrimmer()
    @State private var edit = EditState()
    @State private var undoStack: [EditState] = []
    @State private var redoStack: [EditState] = []

    @State private var playerReady = false
    @State private var cropMode = false
    @State private var cropBeforeEditing: CropRect?
    @State private var isTrimming = false
    @State private var isExporting = false

    @State private var videoSize: CGSize?
    @State private var assetDuration: Double = 0

    /// Identifies this view's leave guard so a stale clear can't wipe another's.
    @State private var exitGuardID = UUID()
    /// The edit state at the last successful export; edits matching it count as
    /// saved, so the leave prompt doesn't fire after exporting.
    @State private var lastExportedEdit: EditState?

    init(source: VideoSource, onClose: @escaping () -> Void) {
        self.source = source
        self.onClose = onClose
        let asset = AVURLAsset(url: source.url)
        _asset = State(initialValue: asset)
        _player = State(initialValue: AVPlayer(playerItem: AVPlayerItem(asset: asset)))
    }

    /// View transforms apply only while not trimming/cropping, so those UIs stay
    /// upright and map to the unrotated frame.
    private var transformActive: Bool { !cropMode && !isTrimming }

    /// Edits exist when the state differs from the default and from the state
    /// last exported — these are lost on leave unless exported first.
    private var hasUnsavedEdits: Bool { edit != EditState() && edit != lastExportedEdit }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            playerSection
            Divider()
            ScrollView { controls.padding(16) }
                .frame(maxHeight: 300)
            Divider()
            bottomBar.padding(12)
        }
        .task(id: source.url) { await loadAsset() }
        .onReceive(player.publisher(for: \.status)) { playerReady = ($0 == .readyToPlay) }
        .onChange(of: hasUnsavedEdits) { _, dirty in
            if dirty {
                state.setExitGuard(.init(
                    id: exitGuardID, style: .edits,
                    title: "Unsaved video edits",
                    message: "Your trim, rotate, crop, and other edits haven’t been exported. Leaving discards them."))
            } else {
                state.clearExitGuard(exitGuardID)
            }
        }
        .onDisappear {
            player.pause()
            state.clearExitGuard(exitGuardID)
        }
    }

    // MARK: player + crop overlay

    private var playerSection: some View {
        GeometryReader { geo in
            ZStack {
                if cropMode {
                    let fitted = fittedVideoRect(in: geo.size)
                    PlayerLayerView(player: player)
                        .frame(width: fitted.width, height: fitted.height)
                    CropBox(crop: bind(\.crop), videoFrame: fitted)
                } else {
                    let size = playerSize(in: geo.size)
                    VideoPlayerView(player: player, trimmer: trimmer)
                        .frame(width: size.width, height: size.height)
                        .overlay {
                            if transformActive, let crop = edit.crop {
                                CropIndicator(crop: crop)
                            }
                        }
                        .rotationEffect(.degrees(transformActive ? Double(edit.rotation) : 0))
                        .scaleEffect(
                            x: transformActive && edit.flipH ? -1 : 1,
                            y: transformActive && edit.flipV ? -1 : 1
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .background(Color.black)
    }

    /// Pre-rotation player size: keeps the video's own aspect (so it fills the
    /// frame) while sizing so the rotated footprint fits the container.
    private func playerSize(in container: CGSize) -> CGSize {
        guard let video = videoSize, video.width > 0, video.height > 0 else { return container }
        let aspect = video.width / video.height
        let swap = transformActive && (((edit.rotation % 360) + 360) % 360) % 180 != 0
        let footprintAspect = swap ? 1 / aspect : aspect
        var width = container.width
        var height = width / footprintAspect
        if height > container.height {
            height = container.height
            width = height * footprintAspect
        }
        return swap ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The unrotated, aspect-fit video rect — where the crop overlay is drawn.
    private func fittedVideoRect(in container: CGSize) -> CGRect {
        guard let size = videoSize, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / size.width, container.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: (container.width - width) / 2, y: (container.height - height) / 2,
            width: width, height: height
        )
    }

    // MARK: controls

    @ViewBuilder private var controls: some View {
        if cropMode {
            cropToolbar
        } else {
            VStack(alignment: .leading, spacing: 14) {
                trimControls
                Divider()
                transformControls
                Divider()
                playbackControls
                Divider()
                exportControls
            }
        }
    }

    // Focused crop mode — only crop actions are available.
    private var cropToolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Crop", systemImage: "crop").font(.headline)
            Text("Drag on the video to select the area to keep, then drag the corner handles to fine-tune. Reset (Esc) clears the selection.")
                .font(.callout).foregroundStyle(.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Reset") { apply { $0.crop = nil } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Cancel") { cancelCrop() }.controlSize(.large)
                Button { applyCrop() } label: {
                    Label("Apply Crop", systemImage: "checkmark").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(edit.crop == nil)
            }
        }
    }

    private var trimControls: some View {
        section("Trim") {
            HStack {
                Button { beginTrim() } label: { Label("Trim…", systemImage: "timeline.selection") }
                    .disabled(!playerReady)
                Spacer()
                Text(trimSummary).foregroundStyle(.textMuted).monospacedDigit()
                if edit.trimStart != nil || edit.trimEnd != nil {
                    Button("Clear") { apply { $0.trimStart = nil; $0.trimEnd = nil } }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var transformControls: some View {
        section("Rotate, flip & crop") {
            HStack(spacing: 10) {
                iconButton("rotate.left", help: "Rotate left") {
                    apply { $0.rotation = ($0.rotation + 270) % 360 }
                }
                iconButton("rotate.right", help: "Rotate right") {
                    apply { $0.rotation = ($0.rotation + 90) % 360 }
                }
                Text(edit.rotation == 0 ? "0°" : "\(edit.rotation)°")
                    .font(.callout).foregroundStyle(.textMuted).monospacedDigit().frame(width: 36)
                Divider().frame(height: 18)
                Toggle("Flip H", isOn: bind(\.flipH)).toggleStyle(EditToggleStyle())
                Toggle("Flip V", isOn: bind(\.flipV)).toggleStyle(EditToggleStyle())
                Spacer()
                Button { enterCropMode() } label: {
                    Label(edit.crop == nil ? "Crop" : "Edit Crop", systemImage: "crop")
                }
                .buttonStyle(.bordered)
                if edit.crop != nil {
                    Button { apply { $0.crop = nil } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.textMuted).help("Remove crop")
                }
            }
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 22, height: 18)
        }
        .buttonStyle(.bordered)
        .help(help)
    }

    private var playbackControls: some View {
        section("Playback") {
            HStack(spacing: 12) {
                Picker("Speed", selection: bind(\.speed)) {
                    Text("0.25×").tag(0.25)
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented).labelsHidden()
                Toggle("Mute", isOn: bind(\.mute)).toggleStyle(EditToggleStyle())
            }
        }
    }

    private var exportControls: some View {
        section("Export") {
            HStack {
                Picker("Format", selection: bind(\.format)) {
                    Text("MP4").tag(VideoFormat.mp4)
                    Text("MOV").tag(VideoFormat.mov)
                    Text("MKV").tag(VideoFormat.mkv)
                    Text("WebM").tag(VideoFormat.webm)
                    Text("GIF").tag(VideoFormat.gif)
                }
                .pickerStyle(.menu).fixedSize()
                Spacer()
                Picker("Compression", selection: bind(\.compression)) {
                    Text("None").tag(CompressionLevel.none)
                    Text("Medium").tag(CompressionLevel.medium)
                    Text("High").tag(CompressionLevel.high)
                }
                .pickerStyle(.menu).fixedSize()
                .disabled(edit.format == .gif)
            }
        }
    }

    /// Top bar with a back button that closes the editor (returns to the mirror /
    /// recorder / file picker that opened it).
    private var editorHeader: some View {
        HStack {
            Button {
                player.pause()
                onClose()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoStack.isEmpty)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoStack.isEmpty)

            Spacer()

            Button { export() } label: {
                Label(isExporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.down")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isExporting || cropMode)
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    // MARK: edits + undo/redo

    /// A binding that snapshots for undo and re-applies playback state on set.
    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<EditState, T>) -> Binding<T> {
        Binding(
            get: { edit[keyPath: keyPath] },
            set: { newValue in
                guard edit[keyPath: keyPath] != newValue else { return }
                undoStack.append(edit)
                redoStack.removeAll()
                edit[keyPath: keyPath] = newValue
                applyPlaybackState()
            }
        )
    }

    private func apply(_ change: (inout EditState) -> Void) {
        var next = edit
        change(&next)
        guard next != edit else { return }
        undoStack.append(edit)
        redoStack.removeAll()
        edit = next
        applyPlaybackState()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        edit = previous
        applyPlaybackState()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        edit = next
        applyPlaybackState()
    }

    private func enterCropMode() {
        cropBeforeEditing = edit.crop
        player.pause()
        cropMode = true
    }

    /// Keep the drawn crop and leave crop mode.
    private func applyCrop() {
        cropMode = false
    }

    /// Leave crop mode, reverting to the crop that was set before editing.
    private func cancelCrop() {
        if edit.crop != cropBeforeEditing { apply { $0.crop = cropBeforeEditing } }
        cropMode = false
    }

    /// Speed and mute are player properties (rotate/flip/crop are view transforms
    /// applied directly in the body, so they need no imperative update).
    private func applyPlaybackState() {
        player.isMuted = edit.mute
        player.defaultRate = Float(edit.speed)
        if player.rate != 0 { player.rate = Float(edit.speed) }
    }

    // MARK: trim

    private var trimSummary: String {
        guard edit.trimStart != nil || edit.trimEnd != nil else { return "Full clip" }
        return "\(timecode(edit.trimStart ?? 0)) – \(timecode(edit.trimEnd ?? assetDuration))"
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func beginTrim() {
        player.pause()
        isTrimming = true
        Task {
            let range = await trimmer.beginTrim()
            isTrimming = false
            guard let range else { return }
            apply {
                $0.trimStart = range.start > 0.05 ? range.start : nil
                $0.trimEnd = (assetDuration > 0 && range.end < assetDuration - 0.05) ? range.end : nil
            }
        }
    }

    // MARK: loading + export

    private func loadAsset() async {
        if let size = await Self.naturalVideoSize(at: source.url) {
            videoSize = size
        }
        if let loaded = try? await asset.load(.duration) { assetDuration = loaded.seconds }
        player.isMuted = edit.mute
    }

    /// Resolve the video's oriented size off the main actor so the non-Sendable
    /// asset and tracks never cross isolation — only the `CGSize` does. (Loading
    /// tracks on the main actor trips Swift 6 strict concurrency under Xcode 16.)
    private nonisolated static func naturalVideoSize(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let props = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let oriented = props.0.applying(props.1)
        return CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }

    private var exportOptions: VideoExportOptions {
        VideoExportOptions(
            trimStart: edit.trimStart, trimEnd: edit.trimEnd, rotationDegrees: edit.rotation,
            flipH: edit.flipH, flipV: edit.flipV, crop: edit.crop, speed: edit.speed,
            mute: edit.mute, compression: edit.compression, format: edit.format
        )
    }

    private func export() {
        let base = source.url.deletingPathExtension().lastPathComponent
        let suggested = "\(base)-edited.\(edit.format.fileExtension)"
        guard let chosen = state.askSaveLocation(suggestedName: suggested) else { return }
        let dest = chosen.deletingPathExtension().appendingPathExtension(edit.format.fileExtension)
        let options = exportOptions
        let exported = edit
        let url = source.url
        isExporting = true
        player.pause()
        Task {
            do {
                let saved = try await state.withOperation("Exporting video…") {
                    try await VideoEditService(
                        locator: state.env.client.locator, bundledPath: BundledTools.ffmpegPath())
                        .export(source: url, options: options, to: dest)
                }
                lastExportedEdit = exported
                state.showToast(Toast(message: "Video exported", ok: true, revealPath: saved.path))
            } catch {
                state.showToast(Toast(message: error.localizedDescription, ok: false))
            }
            isExporting = false
        }
    }
}
