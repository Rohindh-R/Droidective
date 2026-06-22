import AppKit
import CoreImage
import ImageIO
import SwiftUI

/// A markup tool in the screenshot editor.
enum MarkupTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, line, rectangle, ellipse, text, redact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .redact: "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "character.textbox"
        case .redact: "eye.slash"
        }
    }

    /// Tools dragged from a start point to an end point (two-point geometry).
    var isDragShape: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .redact: true
        case .pen, .highlighter, .text: false
        }
    }
}

/// How a redact region obscures what's beneath it.
enum RedactStyle: String, CaseIterable, Identifiable {
    case blur, solid
    var id: String { rawValue }
    var label: String { self == .blur ? "Blur" : "Solid" }
}

/// One markup element. Points are normalized (0...1) to the image, so the same
/// annotation maps to any render size — the on-screen canvas or the
/// full-resolution PNG export.
struct Annotation: Identifiable {
    let id = UUID()
    var tool: MarkupTool
    var color: Color
    /// Stroke weight expressed as points per 1000px of image width, so it scales
    /// with the render size.
    var width: CGFloat
    var points: [CGPoint]
    var text: String = ""
    /// Only meaningful for `.redact`.
    var redactStyle: RedactStyle = .solid
}

extension Annotation {
    /// Normalized (0...1) bounding box. Text gets an approximate extent (its real
    /// size depends on the render width) so it's still selectable and movable.
    var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .text {
            let w = max(0.06, CGFloat(max(text.count, 4)) * 0.011 * (width / 6))
            let h = max(0.03, 0.05 * (width / 6))
            return CGRect(x: first.x, y: first.y, width: w, height: h)
        }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Normalized resize-handle positions. Two-point shapes expose their two
    /// defining points; freehand strokes expose bounding-box corners; text has
    /// none (move only).
    var handlePoints: [CGPoint] {
        switch tool {
        case .line, .arrow, .rectangle, .ellipse, .redact:
            return points.count >= 2 ? [points[0], points[1]] : []
        case .pen, .highlighter:
            let b = boundingBox
            return [
                CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY),
            ]
        case .text:
            return []
        }
    }

    /// Translate every point, clamped so the bounding box stays within 0...1
    /// (the shape moves rigidly and stops at the edge).
    func moved(by delta: CGPoint) -> Annotation {
        let b = boundingBox
        let dx = min(max(delta.x, -b.minX), 1 - b.maxX)
        let dy = min(max(delta.y, -b.minY), 1 - b.maxY)
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    /// Move handle `index` to `target` (normalized). Two-point shapes move that
    /// endpoint; freehand strokes scale every point from the opposite corner.
    func resizing(handle index: Int, to target: CGPoint) -> Annotation {
        let p = CGPoint(x: min(1, max(0, target.x)), y: min(1, max(0, target.y)))
        var copy = self
        switch tool {
        case .line, .arrow, .rectangle, .ellipse, .redact:
            if copy.points.indices.contains(index) { copy.points[index] = p }
        case .pen, .highlighter:
            let b = boundingBox
            let corners = [
                CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY),
            ]
            let anchor = corners[(index + 2) % 4]
            let sx = abs(p.x - anchor.x) / max(b.width, 0.0001)
            let sy = abs(p.y - anchor.y) / max(b.height, 0.0001)
            copy.points = points.map {
                CGPoint(
                    x: min(1, max(0, anchor.x + ($0.x - anchor.x) * sx)),
                    y: min(1, max(0, anchor.y + ($0.y - anchor.y) * sy))
                )
            }
        case .text:
            break
        }
        return copy
    }
}

/// Stateless drawing + rasterization for the screenshot editor. Drawing routines
/// take a normalized annotation list and a target size, so the editor canvas and
/// the export renderer share one code path.
enum ScreenshotMarkup {
    /// Pixel dimensions of a captured image (its first bitmap rep), falling back
    /// to the point size.
    static func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// Draw every annotation (plus an in-progress draft) into a Canvas context
    /// sized `size`. Redact regions, drawn opaque, hide what's beneath them.
    static func draw(_ annotations: [Annotation], draft: Annotation?, in context: GraphicsContext, size: CGSize) {
        for annotation in annotations { drawOne(annotation, in: context, size: size) }
        if let draft { drawOne(draft, in: context, size: size) }
    }

    private static func drawOne(_ a: Annotation, in context: GraphicsContext, size: CGSize) {
        let pts = a.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first else { return }
        let weight = max(1, a.width * size.width / 1000)
        let solid = StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round)

        switch a.tool {
        case .pen:
            context.stroke(freehandPath(pts), with: .color(a.color), style: solid)
        case .highlighter:
            let thick = StrokeStyle(lineWidth: weight * 3.5, lineCap: .round, lineJoin: .round)
            context.stroke(freehandPath(pts), with: .color(a.color.opacity(0.35)), style: thick)
        case .line:
            guard pts.count >= 2 else { return }
            var path = Path(); path.move(to: first); path.addLine(to: pts[1])
            context.stroke(path, with: .color(a.color), style: solid)
        case .arrow:
            guard pts.count >= 2 else { return }
            drawArrow(from: first, to: pts[1], weight: weight, color: a.color, in: context)
        case .rectangle:
            guard pts.count >= 2 else { return }
            context.stroke(Path(roundedRect: rect(first, pts[1]), cornerRadius: weight), with: .color(a.color), style: solid)
        case .ellipse:
            guard pts.count >= 2 else { return }
            context.stroke(Path(ellipseIn: rect(first, pts[1])), with: .color(a.color), style: solid)
        case .redact:
            // Solid fills here; blur regions are drawn by `RedactBlurLayer`
            // beneath this canvas (a 2-D context can't sample the image).
            guard pts.count >= 2, a.redactStyle == .solid else { return }
            context.fill(Path(rect(first, pts[1])), with: .color(a.color))
        case .text:
            let fontSize = max(11, size.width * 0.03 * (a.width / 6))
            let label = Text(a.text.isEmpty ? "Text" : a.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(a.color)
            context.draw(label, at: first, anchor: .topLeading)
        }
    }

    private static func freehandPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, weight: CGFloat, color: Color, in context: GraphicsContext) {
        var shaft = Path(); shaft.move(to: start); shaft.addLine(to: end)
        context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: weight, lineCap: .round))
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = max(10, weight * 4)
        var tips = Path()
        tips.move(to: end)
        tips.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 7) * head, y: end.y - sin(angle - .pi / 7) * head))
        tips.move(to: end)
        tips.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 7) * head, y: end.y - sin(angle + .pi / 7) * head))
        context.stroke(tips, with: .color(color), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Normalized rects of every blur-style redact region (plus an in-progress
    /// draft) — drawn by `RedactBlurLayer`, not the 2-D canvas.
    static func blurRects(_ annotations: [Annotation], draft: Annotation?) -> [CGRect] {
        var result: [CGRect] = []
        for a in annotations where a.tool == .redact && a.redactStyle == .blur && a.points.count >= 2 {
            result.append(rect(a.points[0], a.points[1]))
        }
        if let d = draft, d.tool == .redact, d.redactStyle == .blur, d.points.count >= 2 {
            result.append(rect(d.points[0], d.points[1]))
        }
        return result
    }

    // MARK: - Hit-testing (display-pixel space, so it's isotropic)

    /// Index of the top-most annotation under `point` (display px), or nil. Area
    /// shapes hit inside their box; strokes/lines hit near their path.
    static func hitTest(_ annotations: [Annotation], atDisplay point: CGPoint, display: CGSize, tolerance: CGFloat) -> Int? {
        for index in annotations.indices.reversed() where hits(annotations[index], point, display, tolerance) {
            return index
        }
        return nil
    }

    private static func hits(_ a: Annotation, _ p: CGPoint, _ display: CGSize, _ tol: CGFloat) -> Bool {
        switch a.tool {
        case .rectangle, .ellipse, .redact, .text:
            let b = a.boundingBox
            let box = CGRect(
                x: b.minX * display.width, y: b.minY * display.height,
                width: b.width * display.width, height: b.height * display.height
            )
            return box.insetBy(dx: -tol, dy: -tol).contains(p)
        case .pen, .highlighter, .line, .arrow:
            let pts = a.points.map { CGPoint(x: $0.x * display.width, y: $0.y * display.height) }
            return distanceToPolyline(pts, p) <= tol
        }
    }

    private static func distanceToPolyline(_ pts: [CGPoint], _ p: CGPoint) -> CGFloat {
        guard let first = pts.first else { return .greatestFiniteMagnitude }
        if pts.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<(pts.count - 1) { best = min(best, distance(p, segment: pts[i], pts[i + 1])) }
        return best
    }

    private static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 1e-9 { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Rasterization

    /// Rotate an image 90° (clockwise or counter-clockwise) at pixel resolution.
    @MainActor
    static func rotated(_ image: NSImage, clockwise: Bool) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let oriented = CIImage(cgImage: cg).oriented(clockwise ? .right : .left)
        guard let out = CIContext().createCGImage(oriented, from: oriented.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    /// Flatten the base image + annotations into a new image at the base's pixel
    /// resolution.
    @MainActor
    static func flatten(_ image: NSImage, annotations: [Annotation]) -> NSImage? {
        let size = pixelSize(of: image)
        let composite = ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
            RedactBlurLayer(image: image, rects: blurRects(annotations, draft: nil))
                .frame(width: size.width, height: size.height)
            Canvas { context, canvasSize in
                draw(annotations, draft: nil, in: context, size: canvasSize)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: composite)
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Flatten, then crop to a normalized rectangle. Returns a new image.
    @MainActor
    static func crop(_ image: NSImage, annotations: [Annotation], to normalized: CGRect) -> NSImage? {
        guard let flat = flatten(image, annotations: annotations),
              let cg = flat.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pxRect = CGRect(
            x: (normalized.minX * w).rounded(),
            y: (normalized.minY * h).rounded(),
            width: (normalized.width * w).rounded(),
            height: (normalized.height * h).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pxRect.width >= 1, pxRect.height >= 1, let cropped = cg.cropping(to: pxRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// PNG bytes for an image at its pixel resolution.
    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Blur-style redaction: a blurred copy of the base image masked to the redact
/// rectangles, layered beneath the markup canvas. Shared by the live editor and
/// the export renderer so blur is WYSIWYG. `rects` are normalized (0...1).
struct RedactBlurLayer: View {
    let image: NSImage
    let rects: [CGRect]

    var body: some View {
        if rects.isEmpty {
            Color.clear
        } else {
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: max(8, geo.size.width * 0.02))
                    .mask {
                        Canvas { context, size in
                            for r in rects {
                                let scaled = CGRect(
                                    x: r.minX * size.width, y: r.minY * size.height,
                                    width: r.width * size.width, height: r.height * size.height
                                )
                                context.fill(Path(scaled), with: .color(.white))
                            }
                        }
                    }
            }
            .allowsHitTesting(false)
        }
    }
}
