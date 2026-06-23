import Testing
@testable import ADBKit

@Suite struct ScreenRecordOptionsTests {
    @Test func defaultsAreHeadlessRecord() {
        // Audio on by default → no --no-audio; all caps at 0 → no other flags.
        #expect(ScreenRecordOptions().args(recordingPath: "/tmp/r.mp4")
            == ["--no-playback", "--record", "/tmp/r.mp4"])
    }

    @Test func noPathStillRunsHeadless() {
        #expect(ScreenRecordOptions().args() == ["--no-playback"])
    }

    @Test func buildsAllFlagsInOrder() {
        let options = ScreenRecordOptions(
            maxSize: 1280, bitRateMbps: 8, maxFps: 60,
            captureAudio: false, timeLimitSeconds: 120
        )
        #expect(options.args(recordingPath: "/tmp/r.mp4") == [
            "--no-playback",
            "--record", "/tmp/r.mp4",
            "--max-size", "1280",
            "--video-bit-rate", "8M",
            "--max-fps", "60",
            "--no-audio",
            "--time-limit", "120",
        ])
    }

    @Test func audioOnEmitsNoNoAudioFlag() {
        #expect(!ScreenRecordOptions(captureAudio: true).args().contains("--no-audio"))
    }

    @Test func skipsRecordWhenPathEmpty() {
        let args = ScreenRecordOptions().args(recordingPath: "")
        #expect(args == ["--no-playback"])
        #expect(!args.contains("--record"))
    }
}

@Suite struct ScrcpyEnvironmentTests {
    @Test func injectsAdbAndPrependsToolDirsToPath() {
        let env = ScreenTools.scrcpyEnvironment(
            base: ["PATH": "/usr/bin"],
            scrcpyPath: "/opt/homebrew/bin/scrcpy",
            adbPath: "/opt/android/platform-tools/adb"
        )
        #expect(env["ADB"] == "/opt/android/platform-tools/adb")
        #expect(env["PATH"] == "/opt/android/platform-tools:/opt/homebrew/bin:/usr/bin")
    }

    @Test func fallsBackWhenBaseHasNoPath() {
        let env = ScreenTools.scrcpyEnvironment(base: [:], scrcpyPath: "/a/scrcpy", adbPath: "/b/adb")
        #expect(env["PATH"] == "/b:/a:/usr/bin:/bin")
    }

    @Test func preservesOtherBaseVariables() {
        let env = ScreenTools.scrcpyEnvironment(
            base: ["HOME": "/Users/x", "PATH": "/p"], scrcpyPath: "/a/scrcpy", adbPath: "/b/adb"
        )
        #expect(env["HOME"] == "/Users/x")
    }
}
