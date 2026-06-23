import Foundation

/// Parameters for the device-side `scrcpy-server`, started via `app_process`.
///
/// Unlike the desktop scrcpy binary's CLI flags, these are the
/// `key=value` arguments the server itself parses. The in-app mirror reuses
/// scrcpy's server but speaks its protocol directly, so we launch the server
/// ourselves over `adb shell`. Kept pure/`Equatable` so the argument building is
/// unit-testable without spawning anything.
///
/// Confirmed against scrcpy 4.0 (`server.c` `execute_server` + live capture):
/// only non-default values are emitted — the server fills in its own defaults,
/// matching how the stock client builds the command.
public struct ScrcpyServerParams: Sendable, Equatable {
    /// Session id; also names the local abstract socket (`scrcpy_<scid>`).
    public var scid: UInt32
    public var logLevel: String
    public var video: Bool
    public var audio: Bool
    public var control: Bool
    /// Longest side in px (0 = device size).
    public var maxSize: Int
    /// Video bit-rate in bits/sec (0 = server default, ~8 Mbps).
    public var videoBitRate: Int
    /// Frame-rate cap (0 = unlimited).
    public var maxFps: Int
    /// Forward tunnel: the server listens and the client connects.
    public var tunnelForward: Bool

    public init(
        scid: UInt32,
        logLevel: String = "info",
        video: Bool = true,
        audio: Bool = false,
        control: Bool = false,
        maxSize: Int = 0,
        videoBitRate: Int = 0,
        maxFps: Int = 0,
        tunnelForward: Bool = true
    ) {
        self.scid = scid
        self.logLevel = logLevel
        self.video = video
        self.audio = audio
        self.control = control
        self.maxSize = maxSize
        self.videoBitRate = videoBitRate
        self.maxFps = maxFps
        self.tunnelForward = tunnelForward
    }

    /// The local abstract socket name the server listens on.
    public var socketName: String { String(format: "scrcpy_%08x", scid) }

    /// The `key=value` parameters, in scrcpy's own order. `scid` and `log_level`
    /// are always present; the rest are emitted only when they differ from the
    /// server's defaults (`video`/`audio`/`control` default on, caps default off).
    public func parameters() -> [String] {
        var params = [
            String(format: "scid=%08x", scid),
            "log_level=\(logLevel)",
        ]
        if !video { params.append("video=false") }
        if videoBitRate > 0 { params.append("video_bit_rate=\(videoBitRate)") }
        if !audio { params.append("audio=false") }
        if maxSize > 0 { params.append("max_size=\(maxSize)") }
        if maxFps > 0 { params.append("max_fps=\(maxFps)") }
        if tunnelForward { params.append("tunnel_forward=true") }
        if !control { params.append("control=false") }
        return params
    }

    /// Full `adb shell` arguments (append after `-s <serial>`): runs the server
    /// jar through `app_process`. `serverVersion` MUST match the pushed jar or the
    /// server aborts with a version-mismatch error.
    public func shellArguments(serverVersion: String, remoteJarPath: String) -> [String] {
        [
            "shell",
            "CLASSPATH=\(remoteJarPath)",
            "app_process", "/",
            "com.genymobile.scrcpy.Server", serverVersion,
        ] + parameters()
    }
}
