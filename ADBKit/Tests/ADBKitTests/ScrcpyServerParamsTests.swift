import Foundation
import Testing
@testable import ADBKit

@Suite struct ScrcpyServerParamsTests {
    @Test func socketNameFormatsScidAsEightHexDigits() {
        #expect(ScrcpyServerParams(scid: 0x1a2b_3c4d).socketName == "scrcpy_1a2b3c4d")
        #expect(ScrcpyServerParams(scid: 0x0000_00ff).socketName == "scrcpy_000000ff")
    }

    @Test func phase1ViewOnlyParameters() {
        // Defaults: video on, audio off, control off (view-only), forward tunnel.
        #expect(ScrcpyServerParams(scid: 0x1a2b_3c4d).parameters() == [
            "scid=1a2b3c4d",
            "log_level=info",
            "audio=false",
            "tunnel_forward=true",
            "control=false",
        ])
    }

    @Test func emitsOnlyNonDefaultOptions() {
        let params = ScrcpyServerParams(
            scid: 0x0000_0001, logLevel: "debug",
            video: true, audio: false, control: true,
            maxSize: 800, videoBitRate: 8_000_000, maxFps: 60, tunnelForward: true)
        #expect(params.parameters() == [
            "scid=00000001",
            "log_level=debug",
            "video_bit_rate=8000000",
            "audio=false",
            "max_size=800",
            "max_fps=60",
            "tunnel_forward=true",
        ])
        // control on (the server default) => no control=false emitted.
        #expect(!params.parameters().contains("control=false"))
    }

    @Test func audioEnabledRequestsRawPcm() {
        // audio on => no audio=false, and the non-default raw codec is requested.
        let params = ScrcpyServerParams(
            scid: 0x0000_0001, audio: true, control: true, maxSize: 1280)
        let args = params.parameters()
        #expect(args == [
            "scid=00000001",
            "log_level=info",
            "audio_codec=raw",
            "max_size=1280",
            "tunnel_forward=true",
        ])
        #expect(!args.contains("audio=false"))
    }

    @Test func opusAudioOmitsCodecArg() {
        // Opus is the server default, so requesting it emits no audio_codec.
        let params = ScrcpyServerParams(scid: 0x1, audio: true, audioCodec: "opus")
        #expect(!params.parameters().contains { $0.hasPrefix("audio_codec=") })
        #expect(!params.parameters().contains("audio=false"))
    }

    @Test func shellArgumentsRunTheServerJar() {
        #expect(ScrcpyServerParams(scid: 0x1a2b_3c4d)
            .shellArguments(serverVersion: "4.0", remoteJarPath: "/data/local/tmp/scrcpy-server.jar") == [
                "shell",
                "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
                "app_process", "/",
                "com.genymobile.scrcpy.Server", "4.0",
                "scid=1a2b3c4d", "log_level=info", "audio=false", "tunnel_forward=true", "control=false",
            ])
    }
}
