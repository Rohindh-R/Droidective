import ADBKit
import SwiftUI

/// A crop selection over the video. Drag on empty space to draw it; once drawn,
/// drag the body to move it and the corner handles to resize it. Stored
/// normalized (0…1) to the video frame so export maps it with ffmpeg `iw`/`ih`.
/// The binding is written once per gesture (on release) so each adjustment is a
/// single undo step.
struct CropBox: View {
    @Binding var crop: CropRect?
    let videoFrame: CGRect

    @State private var draft: CGRect?
    @State private var gestureStart: CGRect?

    private let handleSize: CGFloat = 14
    private let minSize: CGFloat = 28

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        ZStack {
            dimmingAndBorder
            // Keep the draw surface mounted until a crop is committed, so a single
            // drag can draw the whole rectangle without the view swapping mid-drag.
            if crop == nil {
                createSurface
            } else if let rect = displayRect {
                moveSurface(rect)
                ForEach(Corner.allCases, id: \.self) { corner in
                    handle
                        .position(point(of: corner, in: rect))
                        .gesture(resizeGesture(corner))
                }
            }
        }
    }

    private var displayRect: CGRect? {
        if let draft { return draft }
        if let crop { return denormalize(crop) }
        return nil
    }

    private var dimmingAndBorder: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.4)))
            guard let rect = displayRect else { return }
            context.blendMode = .destinationOut
            context.fill(Path(rect), with: .color(.black))
            context.blendMode = .normal
            context.stroke(Path(rect), with: .color(.brandAccent), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }

    private var handle: some View {
        Circle()
            .fill(Color.brandAccent)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: handleSize, height: handleSize)
    }

    private func moveSurface(_ rect: CGRect) -> some View {
        Color.white.opacity(0.001)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = gestureStart ?? rect
                        if gestureStart == nil { gestureStart = rect }
                        let moved = base.offsetBy(dx: value.translation.width, dy: value.translation.height)
                        draft = clampInside(moved)
                    }
                    .onEnded { _ in commit() }
            )
    }

    private var createSurface: some View {
        Color.white.opacity(0.001)
            .frame(width: videoFrame.width, height: videoFrame.height)
            .position(x: videoFrame.midX, y: videoFrame.midY)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let start = clampPoint(value.startLocation)
                        let current = clampPoint(value.location)
                        draft = CGRect(
                            x: min(start.x, current.x), y: min(start.y, current.y),
                            width: abs(current.x - start.x), height: abs(current.y - start.y)
                        )
                    }
                    .onEnded { _ in commit() }
            )
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = gestureStart ?? displayRect ?? .zero
                if gestureStart == nil { gestureStart = base }
                draft = clampInside(resized(base, corner: corner, to: clampPoint(value.location)))
            }
            .onEnded { _ in commit() }
    }

    // MARK: geometry

    private func point(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func resized(_ rect: CGRect, corner: Corner, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch corner {
        case .topLeft: minX = point.x; minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .bottomRight: maxX = point.x; maxY = point.y
        }
        let x0 = min(minX, maxX), x1 = max(minX, maxX)
        let y0 = min(minY, maxY), y1 = max(minY, maxY)
        return CGRect(x: x0, y: y0, width: max(minSize, x1 - x0), height: max(minSize, y1 - y0))
    }

    private func clampInside(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, videoFrame.width)
        result.size.height = min(result.height, videoFrame.height)
        result.origin.x = min(max(result.minX, videoFrame.minX), videoFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, videoFrame.minY), videoFrame.maxY - result.height)
        return result
    }

    private func clampPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, videoFrame.minX), videoFrame.maxX),
            y: min(max(point.y, videoFrame.minY), videoFrame.maxY)
        )
    }

    private func denormalize(_ crop: CropRect) -> CGRect {
        CGRect(
            x: videoFrame.minX + crop.x * videoFrame.width,
            y: videoFrame.minY + crop.y * videoFrame.height,
            width: crop.width * videoFrame.width,
            height: crop.height * videoFrame.height
        )
    }

    private func commit() {
        defer { draft = nil; gestureStart = nil }
        guard let rect = draft, videoFrame.width > 0, videoFrame.height > 0,
              rect.width > minSize / 2, rect.height > minSize / 2 else { return }
        let clamped = clampInside(rect)
        crop = CropRect(
            x: (clamped.minX - videoFrame.minX) / videoFrame.width,
            y: (clamped.minY - videoFrame.minY) / videoFrame.height,
            width: clamped.width / videoFrame.width,
            height: clamped.height / videoFrame.height
        )
    }
}
