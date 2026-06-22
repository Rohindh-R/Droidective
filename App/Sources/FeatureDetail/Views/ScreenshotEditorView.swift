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
    /// Select-mode editing: tap an existing annotation to select it, drag its
    /// body to move it, drag a handle to resize it.
    @State private var selecting = false
    @State private var selectedID: Annotation.ID?
    @State private var selectDragActive = false
    @State private var selectDragMode: SelectDragMode = .none
    /// The selected annotation as it was when the drag began, so each frame
    /// transforms from the original rather than accumulating drift.
    @State private var selectDragOrigin: Annotation?
    @State private var selectDragStart: CGPoint = .zero
    @State private var selectDidEdit = false
    /// Redact defaults for new regions (per-annotation values live on `Annotation`).
    @State private var blurStrength: Double = 0.4
    @State private var fillOpacity: Double = 1
    /// The text annotation currently being re-edited (nil = placing new text).
    @State private var editingTextID: Annotation.ID?

    private static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
    private static let widths: [(String, CGFloat)] = [("Thin", 3), ("Medium", 6), ("Thick", 12)]
    /// Cap the undo history so a long session can't grow it without bound. A crop
    /// replaces the base image, so a snapshot can hold a full-resolution copy.
    private static let maxUndo = 50

    init(image: NSImage, onClose: @escaping () -> Void) {
        _image = State(initialValue: image)
        self.onClose = onClose
    }

    private var pixelSize: CGSize { ScreenshotMarkup.pixelSize(of: image) }

    private var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    /// Annotations drawn on the canvas — minus the text being re-edited, which
    /// shows in the live text field instead.
    private var visibleAnnotations: [Annotation] {
        guard let editingTextID else { return annotations }
        return annotations.filter { $0.id != editingTextID }
    }

    private var editingAnnotation: Annotation? {
        guard let editingTextID else { return nil }
        return annotations.first { $0.id == editingTextID }
    }
    private var activeTextColor: Color { editingAnnotation?.color ?? color }
    private var activeTextWidth: CGFloat { editingAnnotation?.width ?? width }

    // Redact controls drive the selected redact when one is selected, else the
    // defaults applied to new redactions.
    private var editingRedact: Annotation? {
        guard selecting, let annotation = selectedAnnotation, annotation.tool == .redact else { return nil }
        return annotation
    }
    private var showsRedactControls: Bool { (tool == .redact && !selecting) || editingRedact != nil }
    private var activeRedactStyle: RedactStyle { editingRedact?.redactStyle ?? redactStyle }

    private var redactStyleBinding: Binding<RedactStyle> {
        Binding(
            get: { activeRedactStyle },
            set: { value in
                if let id = editingRedact?.id { pushUndo(); updateAnnotation(id) { $0.redactStyle = value } }
                else { redactStyle = value }
            }
        )
    }
    private var blurBinding: Binding<Double> {
        Binding(
            get: { editingRedact?.blurStrength ?? blurStrength },
            set: { value in
                if let id = editingRedact?.id { updateAnnotation(id) { $0.blurStrength = value } }
                else { blurStrength = value }
            }
        )
    }
    private var opacityBinding: Binding<Double> {
        Binding(
            get: { editingRedact?.fillOpacity ?? fillOpacity },
            set: { value in
                if let id = editingRedact?.id { updateAnnotation(id) { $0.fillOpacity = value } }
                else { fillOpacity = value }
            }
        )
    }
    private func updateAnnotation(_ id: Annotation.ID, _ mutate: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&annotations[index])
    }

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

    /// Undo/redo are unavailable while a text label is being typed, so ⌘Z falls
    /// through to the text field — and the toolbar buttons stay in lockstep with
    /// the Edit menu.
    private var canUndo: Bool { textPoint == nil && !undoStack.isEmpty }
    private var canRedo: Bool { textPoint == nil && !redoStack.isEmpty }

    private var editCommands: ScreenshotEditCommands {
        ScreenshotEditCommands(
            undo: canUndo ? { undo() } : nil,
            redo: canRedo ? { redo() } : nil
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button {
                    selecting = true
                    cropping = false
                } label: {
                    Image(systemName: "cursorarrow")
                        .frame(width: 26, height: 24)
                        .background(selecting ? AnyShapeStyle(.brandAccent.opacity(0.18)) : AnyShapeStyle(.clear),
                                   in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(selecting ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMain))
                }
                .buttonStyle(.plain)
                .help("Select, move & resize")

                ForEach(MarkupTool.allCases) { item in
                    Button {
                        tool = item
                        cropping = false
                        selecting = false
                        selectedID = nil
                    } label: {
                        Image(systemName: item.systemImage)
                            .frame(width: 26, height: 24)
                            .background(tool == item && !cropping && !selecting ? AnyShapeStyle(.brandAccent.opacity(0.18)) : AnyShapeStyle(.clear),
                                       in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(tool == item && !cropping && !selecting ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.textMain))
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
                // Native color picker, masked behind a color-wheel "logo" so it
                // reads as "pick any color" instead of a plain swatch. The wheel
                // is non-interactive, so taps fall through to the picker.
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .fill(AngularGradient(
                                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center
                            ))
                            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, 6)
                    .help("Custom color")
            }

            Divider().frame(height: 22)

            Picker("", selection: $width) {
                ForEach(Self.widths, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Stroke width")

            if showsRedactControls {
                Picker("", selection: redactStyleBinding) {
                    ForEach(RedactStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Redaction style")

                HStack(spacing: 5) {
                    Image(systemName: activeRedactStyle == .blur ? "drop.fill" : "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.textMuted)
                    Slider(
                        value: activeRedactStyle == .blur ? blurBinding : opacityBinding,
                        in: activeRedactStyle == .blur ? 0.0...1.0 : 0.1...1.0,
                        onEditingChanged: { editing in if editing, editingRedact != nil { pushUndo() } }
                    )
                    .frame(width: 88)
                }
                .help(activeRedactStyle == .blur ? "Blur amount" : "Fill opacity")
            }

            if selecting, selectedAnnotation?.tool == .text {
                Button { beginEditingSelectedText() } label: {
                    Label("Edit Text", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .help("Edit the selected text")
            }

            Spacer()

            Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .buttonStyle(.bordered)
                .help("Rotate left 90°")
            Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .buttonStyle(.bordered)
                .help("Rotate right 90°")

            Button { cropping.toggle(); cropRect = nil; selecting = false; selectedID = nil } label: {
                Image(systemName: "crop")
            }
            .buttonStyle(.bordered)
            .tint(cropping ? .brandAccent : nil)
            .help("Crop the image")

            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.bordered)
                .disabled(!canUndo)
                .help("Undo (⌘Z)")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.bordered)
                .disabled(!canRedo)
                .help("Redo (⇧⌘Z)")
            Button {
                if selecting, selectedID != nil { deleteSelected() } else { clearAll() }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.bordered)
                .disabled(selecting ? selectedID == nil : annotations.isEmpty)
                .help(selecting && selectedID != nil ? "Delete selection" : "Clear all markup")
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
                RedactBlurLayer(image: image, regions: ScreenshotMarkup.blurRegions(annotations, draft: draft))
            }
            .overlay {
                Canvas { context, size in
                    ScreenshotMarkup.draw(visibleAnnotations, draft: draft, in: context, size: size)
                }
            }
            .overlay { if selecting, textPoint == nil { selectionOverlay(display: display) } }
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

    /// Dashed bounding box, resize handles, and a rotation handle around the
    /// selected annotation. The box and handles follow the annotation's rotation.
    private func selectionOverlay(display: CGSize) -> some View {
        Canvas { context, size in
            guard let annotation = selectedAnnotation else { return }
            func dot(_ p: CGPoint) {
                let rect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: rect), with: .color(.white))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.65)), style: StrokeStyle(lineWidth: 1))
            }

            let b = ScreenshotMarkup.bounds(annotation, in: size)
            let center = CGPoint(x: b.midX * size.width, y: b.midY * size.height)
            let pad: CGFloat = 5
            var corners = [
                CGPoint(x: b.minX * size.width - pad, y: b.minY * size.height - pad),
                CGPoint(x: b.maxX * size.width + pad, y: b.minY * size.height - pad),
                CGPoint(x: b.maxX * size.width + pad, y: b.maxY * size.height + pad),
                CGPoint(x: b.minX * size.width - pad, y: b.maxY * size.height + pad),
            ]
            if annotation.rotation != 0 {
                corners = corners.map { ScreenshotMarkup.rotate($0, around: center, by: annotation.rotation) }
            }
            var boxPath = Path()
            boxPath.move(to: corners[0])
            corners.dropFirst().forEach { boxPath.addLine(to: $0) }
            boxPath.closeSubpath()
            context.stroke(boxPath, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))

            if let rotationHandle = annotation.rotationHandle(in: size) {
                let topMid = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
                let point = CGPoint(x: rotationHandle.x * size.width, y: rotationHandle.y * size.height)
                var line = Path(); line.move(to: topMid); line.addLine(to: point)
                context.stroke(line, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5))
                dot(point)
            }

            for handle in annotation.handlePoints(in: size) {
                dot(CGPoint(x: handle.x * size.width, y: handle.y * size.height))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func textEditor(display: CGSize) -> some View {
        if let textPoint {
            let point = CGPoint(x: textPoint.x * display.width, y: textPoint.y * display.height)
            // Mirror the committed annotation's font and top-leading anchor
            // (ScreenshotMarkup.drawOne) so the text doesn't jump in size or
            // position the moment it's committed.
            let fontSize = max(11, display.width * 0.03 * (activeTextWidth / 6))
            let fieldWidth = max(120, display.width - point.x - 8)
            TextField("Type, then ⏎", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(activeTextColor)
                .focused($textFocused)
                .frame(width: fieldWidth, alignment: .leading)
                .position(x: point.x + fieldWidth / 2, y: point.y + fontSize / 2)
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
                } else if selecting {
                    selectChanged(value: value, display: display)
                } else if tool.isDragShape {
                    let start = normalize(value.startLocation, in: display)
                    draft = Annotation(tool: tool, color: color, width: width, points: [start, norm], redactStyle: redactStyle, blurStrength: blurStrength, fillOpacity: fillOpacity)
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
                if selecting { selectEnded(); return }
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
                    selectAfterDrawing(finished.id)
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

    /// Re-open the selected text annotation for editing (its content only —
    /// color and size are preserved).
    private func beginEditingSelectedText() {
        guard let annotation = selectedAnnotation, annotation.tool == .text,
              let point = annotation.points.first else { return }
        editingTextID = annotation.id
        editingText = annotation.text
        textPoint = point
        textFocused = true
    }

    private func commitText() {
        let committedPoint = textPoint
        let editID = editingTextID
        textPoint = nil
        textFocused = false
        editingTextID = nil
        guard let committedPoint else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editID, let index = annotations.firstIndex(where: { $0.id == editID }) {
            // Editing existing text: update content (or delete if emptied).
            pushUndo()
            if trimmed.isEmpty {
                annotations.remove(at: index)
                selectedID = nil
            } else {
                annotations[index].text = trimmed
                selectedID = editID
            }
        } else {
            guard !trimmed.isEmpty else { return }
            pushUndo()
            let annotation = Annotation(tool: .text, color: color, width: width, points: [committedPoint], text: trimmed)
            annotations.append(annotation)
            selectAfterDrawing(annotation.id)
        }
    }

    private func clearAll() {
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations.removeAll()
        draft = nil
        selectedID = nil
    }

    // MARK: - Select / move / resize

    private func selectChanged(value: DragGesture.Value, display: CGSize) {
        let current = normalize(value.location, in: display)
        if !selectDragActive {
            selectDragActive = true
            selectDidEdit = false
            selectDragStart = normalize(value.startLocation, in: display)
            beginSelectDrag(atDisplay: value.startLocation, display: display)
        }
        guard let origin = selectDragOrigin else { return }
        let delta = CGPoint(x: current.x - selectDragStart.x, y: current.y - selectDragStart.y)
        if !selectDidEdit {
            guard abs(delta.x) > 0.002 || abs(delta.y) > 0.002 else { return }
            pushUndo()
            selectDidEdit = true
        }
        guard let index = annotations.firstIndex(where: { $0.id == origin.id }) else { return }
        switch selectDragMode {
        case .move: annotations[index] = origin.moved(by: delta)
        case .resize(let handle): annotations[index] = origin.resizing(handle: handle, to: current, in: display)
        case .rotate: annotations[index] = origin.rotated(toward: current, in: display)
        case .none: break
        }
    }

    /// On drag start, decide what was grabbed: a handle of the current selection,
    /// the body of an annotation (selecting it), or empty space (deselect).
    private func beginSelectDrag(atDisplay point: CGPoint, display: CGSize) {
        if let selected = selectedAnnotation {
            if let rotationHandle = selected.rotationHandle(in: display) {
                let inPixels = CGPoint(x: rotationHandle.x * display.width, y: rotationHandle.y * display.height)
                if hypot(point.x - inPixels.x, point.y - inPixels.y) <= 14 {
                    selectDragMode = .rotate
                    selectDragOrigin = selected
                    return
                }
            }
            for (handle, position) in selected.handlePoints(in: display).enumerated() {
                let inPixels = CGPoint(x: position.x * display.width, y: position.y * display.height)
                if hypot(point.x - inPixels.x, point.y - inPixels.y) <= 12 {
                    selectDragMode = .resize(handle)
                    selectDragOrigin = selected
                    return
                }
            }
        }
        if let index = ScreenshotMarkup.hitTest(annotations, atDisplay: point, display: display, tolerance: 10) {
            selectedID = annotations[index].id
            selectDragMode = .move
            selectDragOrigin = annotations[index]
        } else {
            selectedID = nil
            selectDragMode = .none
            selectDragOrigin = nil
        }
    }

    private func selectEnded() {
        selectDragActive = false
        selectDragMode = .none
        selectDragOrigin = nil
        selectDidEdit = false
    }

    /// After a shape/stroke/text is drawn, switch to Select mode with it selected
    /// so it can be moved or resized right away.
    private func selectAfterDrawing(_ id: Annotation.ID) {
        selecting = true
        selectedID = id
    }

    private func deleteSelected() {
        guard let id = selectedID, annotations.contains(where: { $0.id == id }) else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    /// Rotate the image 90°. Current markup is flattened in first (like Crop), so
    /// shapes and text rotate correctly without per-annotation transforms.
    private func rotate(clockwise: Bool) {
        let source = annotations.isEmpty ? image : (flattened() ?? image)
        guard let rotated = ScreenshotMarkup.rotated(source, clockwise: clockwise) else {
            state.showToast(Toast(message: "Couldn't rotate the image", ok: false))
            return
        }
        pushUndo()
        image = rotated
        annotations.removeAll()
        draft = nil
        selectedID = nil
        cropping = false
        cropRect = nil
        zoom = 1
        pinchAnchor = 1
    }

    // MARK: - Undo / redo

    private func pushUndo() {
        undoStack.append(EditorSnapshot(image: image, annotations: annotations))
        if undoStack.count > Self.maxUndo {
            undoStack.removeFirst(undoStack.count - Self.maxUndo)
        }
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
        editingTextID = nil
        cropping = false
        cropRect = nil
        selectedID = nil
        selectDragActive = false
        selectDragMode = .none
        selectDragOrigin = nil
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

/// What a select-mode drag is doing: nothing, moving the selection, or dragging
/// one of its resize handles.
private enum SelectDragMode {
    case none
    case move
    case resize(Int)
    case rotate
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
