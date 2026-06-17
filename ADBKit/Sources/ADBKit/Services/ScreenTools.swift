import Foundation

/// Common scrcpy mirroring options. `args(recordingPath:)` builds the CLI flags
/// (excluding `-s <serial>`), kept pure so it's unit-testable.
public struct ScrcpyOptions: Sendable, Equatable {
    /// Longest side in px (0 = unlimited / device size).
    public var maxSize: Int
    /// Video bit-rate in Mbps (0 = scrcpy default).
    public var bitRateMbps: Int
    /// Frame-rate cap (0 = unlimited).
    public var maxFps: Int
    /// `width:height:x:y` crop, or "" for none.
    public var crop: String
    public var stayAwake: Bool
    public var turnScreenOff: Bool
    /// `--no-control` — mirror without controlling the device.
    public var viewOnly: Bool
    public var alwaysOnTop: Bool
    public var fullscreen: Bool

    public init(
        maxSize: Int = 0,
        bitRateMbps: Int = 0,
        maxFps: Int = 0,
        crop: String = "",
        stayAwake: Bool = false,
        turnScreenOff: Bool = false,
        viewOnly: Bool = false,
        alwaysOnTop: Bool = false,
        fullscreen: Bool = false
    ) {
        self.maxSize = maxSize
        self.bitRateMbps = bitRateMbps
        self.maxFps = maxFps
        self.crop = crop
        self.stayAwake = stayAwake
        self.turnScreenOff = turnScreenOff
        self.viewOnly = viewOnly
        self.alwaysOnTop = alwaysOnTop
        self.fullscreen = fullscreen
    }

    public func args(recordingPath: String? = nil) -> [String] {
        var args: [String] = []
        if maxSize > 0 { args += ["--max-size", String(maxSize)] }
        if bitRateMbps > 0 { args += ["--video-bit-rate", "\(bitRateMbps)M"] }
        if maxFps > 0 { args += ["--max-fps", String(maxFps)] }
        if !crop.isEmpty { args += ["--crop", crop] }
        if stayAwake { args.append("--stay-awake") }
        if turnScreenOff { args.append("--turn-screen-off") }
        if viewOnly { args.append("--no-control") }
        if alwaysOnTop { args.append("--always-on-top") }
        if fullscreen { args.append("--fullscreen") }
        if let recordingPath, !recordingPath.isEmpty { args += ["--record", recordingPath] }
        return args
    }
}

/// `adb shell screenrecord` options. `args()` builds the flags (excluding the
/// on-device output path).
public struct ScreenRecordOptions: Sendable, Equatable {
    /// Bit-rate in Mbps.
    public var bitRateMbps: Int
    /// Output width in px (0 with height 0 = device default).
    public var sizeWidth: Int
    public var sizeHeight: Int
    /// Stop after N seconds (0 = screenrecord's own ~180s cap).
    public var timeLimitSeconds: Int
    public var rotate: Bool
    /// `--bugreport` overlays a timestamp + device-info frame.
    public var bugreport: Bool

    public init(
        bitRateMbps: Int = 8,
        sizeWidth: Int = 0,
        sizeHeight: Int = 0,
        timeLimitSeconds: Int = 0,
        rotate: Bool = false,
        bugreport: Bool = false
    ) {
        self.bitRateMbps = bitRateMbps
        self.sizeWidth = sizeWidth
        self.sizeHeight = sizeHeight
        self.timeLimitSeconds = timeLimitSeconds
        self.rotate = rotate
        self.bugreport = bugreport
    }

    public func args() -> [String] {
        var args = ["--bit-rate", String(max(1, bitRateMbps) * 1_000_000)]
        if sizeWidth > 0, sizeHeight > 0 { args += ["--size", "\(sizeWidth)x\(sizeHeight)"] }
        if timeLimitSeconds > 0 { args += ["--time-limit", String(timeLimitSeconds)] }
        if rotate { args.append("--rotate") }
        if bugreport { args.append("--bugreport") }
        return args
    }
}
