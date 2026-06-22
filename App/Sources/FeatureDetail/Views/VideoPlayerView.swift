import AVFoundation
import AVKit
import SwiftUI

/// Hosts an `AVPlayerView` — native transport controls (play/scrub/volume/
/// frame-step/fullscreen) plus the built-in trim UI. The parent owns the
/// `AVPlayer` so it can drive mute/speed/seek; this view just displays it and
/// routes trim requests through `VideoTrimmer`.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let trimmer: VideoTrimmer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        trimmer.playerView = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        trimmer.playerView = nsView
    }
}

/// A bare `AVPlayerLayer` host with no controls at all — used while cropping so
/// nothing overlays the crop selection.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// Bridges SwiftUI controls to `AVPlayerView`'s built-in trimming UI. After the
/// user commits a trim, AVKit applies the in/out points to the player item as
/// `reversePlaybackEndTime` / `forwardPlaybackEndTime`; we read them back. The
/// trim result is bridged through a continuation so the `@Sendable` AVKit
/// completion captures only the (Sendable) continuation, never the player.
@MainActor
final class VideoTrimmer {
    weak var playerView: AVPlayerView?

    var canTrim: Bool { playerView?.canBeginTrimming ?? false }

    /// Present the trim UI; returns the chosen (start, end) in seconds, or nil if
    /// cancelled. An edge the user didn't move comes back as 0 / full duration.
    func beginTrim() async -> (start: Double, end: Double)? {
        guard let view = playerView, view.canBeginTrimming else { return nil }
        let committed = await withCheckedContinuation { continuation in
            view.beginTrimming { result in continuation.resume(returning: result == .okButton) }
        }
        guard committed, let item = view.player?.currentItem else { return nil }
        let duration = item.duration.seconds
        let startTime = item.reversePlaybackEndTime
        let endTime = item.forwardPlaybackEndTime
        let start = (startTime.isValid && !startTime.isIndefinite) ? max(0, startTime.seconds) : 0
        let end = (endTime.isValid && !endTime.isIndefinite && endTime.seconds > 0)
            ? endTime.seconds : duration
        return (start, end)
    }
}
