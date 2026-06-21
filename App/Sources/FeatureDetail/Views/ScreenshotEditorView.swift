import ADBKit
import AppKit
import SwiftUI

/// Annotate a freshly captured screenshot: pen/highlighter, shapes, arrows,
/// text, and redaction, with zoom, crop, and save-on-demand. Nothing is written
/// to disk until the user saves or copies.
struct ScreenshotEditorView: View {
    @Environment(AppState.self) private var state
    /// Discard the current capture and return to the capture controls.
    let onClose: () -> Void

    @State private var image: NSImage
    @State private var annotations: [Annotation] = []
    /// Past / future states for ⌘Z / ⇧⌘Z — each snapshot is the full
    /// (image, annotations) pair, so undo also reverses a clear or a crop.
    @State private var undoStack: [EditorSnapshot] = []
    @State private var redoStack: [EditorSnapshot] = []
    @State private var draft: Annotation?
    @State private var tool: MarkupTool = .pen
    @State private var color: Color = .red
    @State private var width: CGFloat = 6
    @State private var redactStyle: RedactStyle = .blur
    /// 1.0 == fit-to-view; the displayed scale is `fit * zoom`.
    @State private var zoom: CGFloat = 1
    @State private var pinchAnchor: CGFloat = 1
    @State private var cropping = false
    @State private var cropStart: CGPoint?
    @State private var cropRect: CGRect?
    /// Normalized location of the text field currently being typed (nil = none).
    @State private var textPoint: CGPoint?
    @State private var editingText = ""
    @State private var lastSavedURL: URL?
    @FocusState private var textFocused: Bool

    private static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
    private static let widths: [(String, CGFloat)] = [("Thin", 3), ("Medium", 6), ("Thick", 12)]

    init(image: NSImage, onClose: @escaping () -> Void) {
        _image = State(initialValue: image)
        self.onClose = onClose
    }

    private var pixelSize: CGSize { ScreenshotMarkup.pixelSize(of: image) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
            Divider()
            bottomBar
        }
        // Routes ⌘Z / ⇧⌘Z (defined in the app's Edit menu) to this editor while
        // its window is key. Nil while typing a text label, so ⌘Z falls through
        // to the text field's own undo.
        .focusedSceneValue(\.screenshotEdit, editCommands)
    }

    private var editCommands: ScreenshotEditCommands {
        let canUndo = textPoint == nil && !undoStack.isEmpty
        let canRedo = textPoint == nil && !redoStack.isEmpty
        return ScreenshotEditCommands(
            undo: canUndo ? { undo() } : nil,
            redo: canRedo ? { redo() } : nil
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(MarkupTool.allCases) { item in
                    Button {
                        tool = item
                        cropping = false
                    } label: {
                        Image(systemName: item.systemImage)
                            .frame(width: 26, height: 24)
                            .background(tool == item && !cropping ? AnyShapeStyle(.brandAccent.opacity(0.18)) : AnyShapeStyle(.clear),
                                       in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(tool == item && !cropping ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMain))
                    }
                    .buttonStyle(.plain)
                    .help(item.label)
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 4) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, swatch in
                    Circle()
                        .fill(swatch)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.separator, lineWidth: swatch == .white ? 1 : 0))
                        .overlay(Circle().strokeBorder(.brandAccent, lineWidth: color == swatch ? 2.5 : 0).padding(-2))
                        .onTapGesture { color = swatch }
                }
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36)
                    .help("Custom color")
            }

            Divider().frame(height: 22)

            Picker("", selection: $width) {
                ForEach(Self.widths, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Stroke width")

            if tool == .redact {
                Picker("", selection: $redactStyle) {
                    ForEach(RedactStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Redaction style")
            }

            Spacer()

            Button { cropping.toggle(); cropRect = nil } label: {
                Label("Crop", systemImage: "crop")
            }
            .buttonStyle(.bordered)
            .tint(cropping ? .accentColor : nil)
            .help("Crop the image")

            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.bordered)
                .disabled(undoStack.isEmpty)
                .help("Undo (⌘Z)")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.bordered)
                .disabled(redoStack.isEmpty)
                .help("Redo (⇧⌘Z)")
            Button { clearAll() } label: { Image(systemName: "trash") }
                .buttonStyle(.bordered)
                .disabled(annotations.isEmpty)
                .help("Clear all markup")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / pixelSize.width, geo.size.height / pixelSize.height)
            let scale = max(0.01, fit * zoom)
            let display = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
            ScrollView([.horizontal, .vertical]) {
                imageStack(display: display)
                    .frame(width: display.width, height: display.height)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(Color.black.opacity(0.25))
            .gesture(
                MagnificationGesture()
                    .onChanged { zoom = min(8, max(0.2, pinchAnchor * $0)) }
                    .onEnded { _ in pinchAnchor = zoom }
            )
        }
    }

    private func imageStack(display: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: display.width, height: display.height)
            .overlay {
                RedactBlurLayer(image: image, rects: ScreenshotMarkup.blurRects(annotations, draft: draft))
            }
            .overlay {
                Canvas { context, size in
                    ScreenshotMarkup.draw(annotations, draft: draft, in: context, size: size)
                }
            }
            .overlay { if cropping { cropOverlay(display: display) } }
            .overlay { textEditor(display: display) }
            .contentShape(Rectangle())
            .gesture(drawGesture(display: display))
            .clipped()
    }

    private func cropOverlay(display: CGSize) -> some View {
        Canvas { context, size in
            let r = (cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)).scaled(to: size)
            let dim = GraphicsContext.Shading.color(.black.opacity(0.5))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: r.minY)), with: dim)
            context.fill(Path(CGRect(x: 0, y: r.maxY, width: size.width, height: size.height - r.maxY)), with: dim)
            context.fill(Path(CGRect(x: 0, y: r.minY, width: r.minX, height: r.height)), with: dim)
            context.fill(Path(CGRect(x: r.maxX, y: r.minY, width: size.width - r.maxX, height: r.height)), with: dim)
            context.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func textEditor(display: CGSize) -> some View {
        if let textPoint {
            let point = CGPoint(x: textPoint.x * display.width, y: textPoint.y * display.height)
            let fieldWidth = max(120, display.width - point.x - 8)
            TextField("Type, then ⏎", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: max(13, display.width * 0.03 * (width / 6)), weight: .semibold))
                .foregroundStyle(color)
                .focused($textFocused)
                .frame(width: fieldWidth, alignment: .leading)
                .position(x: point.x + fieldWidth / 2, y: point.y + 10)
                .onSubmit { commitText() }
                .onAppear { textFocused = true }
                .onChange(of: textFocused) { _, focused in if !focused { commitText() } }
        }
    }

    // MARK: - Gestures

    private func drawGesture(display: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if textPoint != nil { return }
                let norm = normalize(value.location, in: display)
                if cropping {
                    let start = cropStart ?? normalize(value.startLocation, in: display)
                    cropStart = start
                    cropRect = CGRect(origin: start, size: .zero).expanded(to: norm)
                } else if tool.isDragShape {
                    let start = normalize(value.startLocation, in: display)
                    draft = Annotation(tool: tool, color: color, width: width, points: [start, norm], redactStyle: redactStyle)
                } else if tool != .text {
                    if draft == nil {
                        draft = Annotation(tool: tool, color: color, width: width, points: [norm])
                    } else {
                        draft?.points.append(norm)
                    }
                }
            }
            .onEnded { value in
                if textPoint != nil { commitText(); return }
                if cropping { cropStart = nil; return }
                if tool == .text {
                    placeText(at: normalize(value.startLocation, in: display))
                    return
                }
                if let finished = draft {
                    if finished.tool.isDragShape, finished.points.count >= 2,
                       finished.points[0].distance(to: finished.points[1]) < 0.004 {
                        draft = nil
                        return
                    }
                    pushUndo()
                    annotations.append(finished)
                    draft = nil
                }
            }
    }

    private func normalize(_ point: CGPoint, in display: CGSize) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x / display.width)),
            y: min(1, max(0, point.y / display.height))
        )
    }

    private func placeText(at point: CGPoint) {
        textPoint = point
        editingText = ""
    }

    private func commitText() {
        defer { textPoint = nil; textFocused = false }
        guard let point = textPoint else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushUndo()
        annotations.append(Annotation(tool: .text, color: color, width: width, points: [point], text: trimmed))
    }

    private func clearAll() {
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations.removeAll()
        draft = nil
    }

    // MARK: - Undo / redo

    private func pushUndo() {
        undoStack.append(EditorSnapshot(image: image, annotations: annotations))
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(EditorSnapshot(image: image, annotations: annotations))
        apply(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditorSnapshot(image: image, annotations: annotations))
        apply(next)
    }

    private func apply(_ snapshot: EditorSnapshot) {
        image = snapshot.image
        annotations = snapshot.annotations
        draft = nil
        textPoint = nil
        cropping = false
        cropRect = nil
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if cropping {
                Text("Drag to choose a crop area")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
                Spacer()
                Button("Cancel") { cropping = false; cropRect = nil }
                Button("Apply Crop") { applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .disabled((cropRect?.width ?? 0) < 0.02 || (cropRect?.height ?? 0) < 0.02)
            } else {
                zoomControls
                Spacer()
                Button { onClose() } label: { Label("New", systemImage: "camera") }
                    .help("Discard and take another")
                if let lastSavedURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.clipboard") }
                Button { save() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { zoom = max(0.2, zoom / 1.25); pinchAnchor = zoom } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = 1; pinchAnchor = 1 } label: { Text("Fit") }
            Button { zoom = min(8, zoom * 1.25); pinchAnchor = zoom } label: { Image(systemName: "plus.magnifyingglass") }
            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.textMuted)
                .frame(width: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Output

    private func applyCrop() {
        guard let rect = cropRect, let cropped = ScreenshotMarkup.crop(image, annotations: annotations, to: rect) else { return }
        pushUndo()
        image = cropped
        annotations.removeAll()
        draft = nil
        cropping = false
        cropRect = nil
        zoom = 1
        pinchAnchor = 1
    }

    private func flattened() -> NSImage? {
        ScreenshotMarkup.flatten(image, annotations: annotations)
    }

    private func copy() {
        guard let flat = flattened() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([flat])
        state.showToast(Toast(message: "Screenshot copied", ok: true))
    }

    private func save() {
        guard let flat = flattened(), let data = ScreenshotMarkup.pngData(flat) else {
            state.showToast(Toast(message: "Couldn't render the screenshot", ok: false))
            return
        }
        guard let dest = state.askSaveLocation(suggestedName: "screenshot_\(ScreenCaptureService.stamp()).png") else { return }
        do {
            try data.write(to: dest)
            lastSavedURL = dest
            state.showToast(Toast(message: "Screenshot saved", ok: true, revealPath: dest.path))
        } catch {
            state.showToast(Toast(message: error.localizedDescription, ok: false))
        }
    }
}

private extension CGRect {
    /// Map a normalized rect (0...1) into a concrete size.
    func scaled(to size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }

    /// A rect spanning the receiver's origin and another point.
    func expanded(to point: CGPoint) -> CGRect {
        CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

/// A point-in-time editor state (image + markup) for undo/redo.
struct EditorSnapshot {
    var image: NSImage
    var annotations: [Annotation]
}

/// Undo/redo actions the editor publishes to the app's Edit menu while its
/// window is key. A nil action disables that menu item (and frees ⌘Z to fall
/// through to a focused text field).
struct ScreenshotEditCommands {
    var undo: (() -> Void)?
    var redo: (() -> Void)?
}

private struct ScreenshotEditCommandsKey: FocusedValueKey {
    typealias Value = ScreenshotEditCommands
}

extension FocusedValues {
    var screenshotEdit: ScreenshotEditCommands? {
        get { self[ScreenshotEditCommandsKey.self] }
        set { self[ScreenshotEditCommandsKey.self] = newValue }
    }
}

/// Replaces the standard Edit-menu Undo/Redo so ⌘Z / ⇧⌘Z drive the screenshot
/// editor when it's frontmost.
struct ScreenshotEditCommandsMenu: Commands {
    @FocusedValue(\.screenshotEdit) private var edit

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { edit?.undo?() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(edit?.undo == nil)
            Button("Redo") { edit?.redo?() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(edit?.redo == nil)
        }
    }
}
