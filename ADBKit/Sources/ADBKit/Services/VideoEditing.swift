import Foundation

/// Output container/codec for an edited video.
public enum VideoFormat: String, Sendable, CaseIterable {
    case mp4, mov, mkv, webm, gif

    public var fileExtension: String { rawValue }

    /// Containers that carry H.264 (the recorder's native codec) — used to
    /// decide when a no-edit export is a lossless file copy.
    var isH264Container: Bool { self == .mp4 || self == .mov || self == .mkv }
}

/// Quality vs. size trade-off, mapped to an x264/VP9 CRF. `.none` keeps quality
/// high; `.high` compresses hardest.
public enum CompressionLevel: String, Sendable, CaseIterable {
    case none, medium, high

    var crf: Int {
        switch self {
        case .none: return 18
        case .medium: return 23
        case .high: return 28
        }
    }
}

/// A crop region in normalized (0…1) coordinates relative to the source frame.
public struct CropRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Covers the whole frame (within rounding) — i.e. not really a crop.
    var isFullFrame: Bool {
        x <= 0.0001 && y <= 0.0001 && width >= 0.9999 && height >= 0.9999
    }
}

/// Non-destructive edit parameters applied at export time.
public struct VideoExportOptions: Sendable, Equatable {
    public var trimStart: Double?
    public var trimEnd: Double?
    /// Clockwise rotation; normalized to 0/90/180/270.
    public var rotationDegrees: Int
    public var flipH: Bool
    public var flipV: Bool
    public var crop: CropRect?
    /// Playback-rate multiplier (2.0 = twice as fast).
    public var speed: Double
    public var mute: Bool
    /// Downscale the output to this width in px (height keeps aspect). nil = keep.
    public var scaleWidth: Int?
    public var compression: CompressionLevel
    public var format: VideoFormat

    public init(
        trimStart: Double? = nil,
        trimEnd: Double? = nil,
        rotationDegrees: Int = 0,
        flipH: Bool = false,
        flipV: Bool = false,
        crop: CropRect? = nil,
        speed: Double = 1.0,
        mute: Bool = false,
        scaleWidth: Int? = nil,
        compression: CompressionLevel = .none,
        format: VideoFormat = .mp4
    ) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.rotationDegrees = rotationDegrees
        self.flipH = flipH
        self.flipV = flipV
        self.crop = crop
        self.speed = speed
        self.mute = mute
        self.scaleWidth = scaleWidth
        self.compression = compression
        self.format = format
    }

    /// No edits at all — the export can be a plain file copy when the format
    /// also matches the source.
    public var isIdentity: Bool {
        trimStart == nil && trimEnd == nil
            && normalizedRotation == 0 && !flipH && !flipV
            && (crop == nil || crop?.isFullFrame == true)
            && speed == 1.0 && !mute && scaleWidth == nil && compression == .none
    }

    var normalizedRotation: Int { ((rotationDegrees % 360) + 360) % 360 }
}

/// Pure ffmpeg argument builder — the test seam for the video editor. UI picks
/// `VideoExportOptions`; this turns them into an ffmpeg invocation.
public enum VideoEditing {
    /// ffmpeg arguments (excluding the `ffmpeg` executable itself) that apply
    /// `options` to `input` and write `output`.
    public static func ffmpegArguments(
        input: String,
        output: String,
        options: VideoExportOptions
    ) -> [String] {
        var args = trimArguments(options)
        args += ["-i", input]
        if options.format == .gif {
            args += gifArguments(options)
        } else {
            args += reencodeArguments(options)
        }
        args += ["-y", output]
        return args
    }

    /// Extract a single still frame as a scaled PNG, for a recording's preview
    /// thumbnail. ffmpeg decodes scrcpy's H.264 reliably where AVAssetImageGenerator
    /// refuses the remuxed stream.
    public static func thumbnailArguments(input: String, output: String) -> [String] {
        ["-i", input, "-frames:v", "1", "-vf", "scale=640:-2", "-y", output]
    }

    /// Losslessly concatenate same-codec segments (the concat demuxer) — used to
    /// stitch a paused/resumed recording's segments back into one file. `listFile`
    /// is an ffmpeg concat list (`file '<path>'` per line); `-safe 0` allows the
    /// absolute temp paths.
    public static func concatArguments(listFile: String, output: String) -> [String] {
        [
            "-f", "concat", "-safe", "0", "-i", listFile,
            "-c", "copy", "-movflags", "+faststart", "-y", output,
        ]
    }

    /// Input-side `-ss`/`-t` so trimming composes correctly with speed changes
    /// (both limit the *input* read; the speed filter then sets output length).
    private static func trimArguments(_ o: VideoExportOptions) -> [String] {
        var args: [String] = []
        if let start = o.trimStart, start > 0 { args += ["-ss", fmt(start)] }
        if let end = o.trimEnd {
            let duration = end - (o.trimStart ?? 0)
            if duration > 0 { args += ["-t", fmt(duration)] }
        }
        return args
    }

    private static func reencodeArguments(_ o: VideoExportOptions) -> [String] {
        var args: [String] = []
        let vf = geometricFilters(o, includeScale: true)
        if !vf.isEmpty { args += ["-vf", vf.joined(separator: ",")] }
        if !o.mute, o.speed != 1.0 { args += ["-af", atempoChain(o.speed).joined(separator: ",")] }

        switch o.format {
        case .webm:
            args += ["-c:v", "libvpx-vp9", "-crf", String(o.compression.crf), "-b:v", "0",
                     "-pix_fmt", "yuv420p"]
            args += o.mute ? ["-an"] : ["-c:a", "libopus"]
        default: // mp4 / mov / mkv → H.264
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", String(o.compression.crf),
                     "-pix_fmt", "yuv420p"]
            args += o.mute ? ["-an"] : ["-c:a", "aac", "-b:a", "128k"]
            if o.format != .mkv { args += ["-movflags", "+faststart"] }
        }
        return args
    }

    /// High-quality GIF via a palette pass; GIF has no audio.
    private static func gifArguments(_ o: VideoExportOptions) -> [String] {
        var chain = geometricFilters(o, includeScale: false)
        chain.append("fps=15")
        chain.append("scale=\(o.scaleWidth ?? 480):-1:flags=lanczos")
        let pre = chain.joined(separator: ",")
        let complex = "[0:v] \(pre),split [a][b];[a] palettegen [p];[b][p] paletteuse"
        return ["-filter_complex", complex, "-an"]
    }

    /// crop → transpose(rotate) → flip → scale → setpts(speed), in that order.
    private static func geometricFilters(_ o: VideoExportOptions, includeScale: Bool) -> [String] {
        var filters: [String] = []
        if let crop = o.crop, !crop.isFullFrame {
            filters.append(
                "crop=iw*\(fmt(crop.width)):ih*\(fmt(crop.height)):iw*\(fmt(crop.x)):ih*\(fmt(crop.y))"
            )
        }
        switch o.normalizedRotation {
        case 90: filters.append("transpose=1")
        case 180: filters += ["transpose=1", "transpose=1"]
        case 270: filters.append("transpose=2")
        default: break
        }
        if o.flipH { filters.append("hflip") }
        if o.flipV { filters.append("vflip") }
        if includeScale, let width = o.scaleWidth { filters.append("scale=\(width):-2") }
        if o.speed != 1.0 { filters.append("setpts=PTS/\(fmt(o.speed))") }
        return filters
    }

    /// `atempo` accepts 0.5…2.0; chain factors to reach any speed.
    private static func atempoChain(_ speed: Double) -> [String] {
        var remaining = speed
        var filters: [String] = []
        while remaining > 2.0 {
            filters.append("atempo=\(fmt(2.0))")
            remaining /= 2.0
        }
        while remaining < 0.5 {
            filters.append("atempo=\(fmt(0.5))")
            remaining /= 0.5
        }
        filters.append("atempo=\(fmt(remaining))")
        return filters
    }

    /// Compact, locale-independent number (decimal point, no trailing zeros).
    private static func fmt(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
