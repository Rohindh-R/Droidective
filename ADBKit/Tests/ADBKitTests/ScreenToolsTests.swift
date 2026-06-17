import Testing
@testable import ADBKit

@Suite struct ScrcpyOptionsTests {
    @Test func defaultsProduceNoFlags() {
        #expect(ScrcpyOptions().args().isEmpty)
    }

    @Test func buildsCommonFlagsInOrder() {
        let options = ScrcpyOptions(
            maxSize: 1024, bitRateMbps: 8, maxFps: 60, crop: "1080:1920:0:0",
            stayAwake: true, turnScreenOff: true, viewOnly: true, alwaysOnTop: true, fullscreen: true
        )
        #expect(options.args(recordingPath: "/tmp/out.mp4") == [
            "--max-size", "1024",
            "--video-bit-rate", "8M",
            "--max-fps", "60",
            "--crop", "1080:1920:0:0",
            "--stay-awake",
            "--turn-screen-off",
            "--no-control",
            "--always-on-top",
            "--fullscreen",
            "--record", "/tmp/out.mp4",
        ])
    }

    @Test func skipsRecordWhenPathEmpty() {
        #expect(!ScrcpyOptions(stayAwake: true).args().contains("--record"))
    }
}

@Suite struct ScreenRecordOptionsTests {
    @Test func defaultsAreJustBitRate() {
        #expect(ScreenRecordOptions().args() == ["--bit-rate", "8000000"])
    }

    @Test func buildsAllFlags() {
        let options = ScreenRecordOptions(
            bitRateMbps: 4, sizeWidth: 1280, sizeHeight: 720,
            timeLimitSeconds: 60, rotate: true, bugreport: true
        )
        #expect(options.args() == [
            "--bit-rate", "4000000",
            "--size", "1280x720",
            "--time-limit", "60",
            "--rotate",
            "--bugreport",
        ])
    }

    @Test func sizeNeedsBothDimensions() {
        #expect(!ScreenRecordOptions(sizeWidth: 1280, sizeHeight: 0).args().contains("--size"))
    }
}
