import Testing
@testable import ADBKit

@Suite struct VideoEditingTests {
    /// The single value following `flag` in an argument list.
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func args(_ options: VideoExportOptions) -> [String] {
        VideoEditing.ffmpegArguments(input: "in.mp4", output: "out", options: options)
    }

    @Test func remuxArgumentsCopyLosslessly() {
        #expect(VideoEditing.remuxArguments(input: "/tmp/r.mp4", output: "/tmp/o.mp4") == [
            "-i", "/tmp/r.mp4", "-c", "copy", "-movflags", "+faststart", "-y", "/tmp/o.mp4",
        ])
    }

    @Test func thumbnailArgumentsGrabOneScaledFrame() {
        #expect(VideoEditing.thumbnailArguments(input: "/tmp/r.mp4", output: "/tmp/t.png") == [
            "-i", "/tmp/r.mp4", "-frames:v", "1", "-vf", "scale=640:-2", "-y", "/tmp/t.png",
        ])
    }

    @Test func concatArgumentsUseLosslessCopy() {
        #expect(VideoEditing.concatArguments(listFile: "/tmp/list.txt", output: "/tmp/out.mp4") == [
            "-f", "concat", "-safe", "0", "-i", "/tmp/list.txt",
            "-c", "copy", "-movflags", "+faststart", "-y", "/tmp/out.mp4",
        ])
    }

    // MARK: defaults / identity

    @Test func defaultMp4ReencodesWithNoFilters() {
        #expect(args(VideoExportOptions()) == [
            "-i", "in.mp4",
            "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            "-y", "out",
        ])
    }

    @Test func defaultOptionsAreIdentity() {
        #expect(VideoExportOptions().isIdentity)
    }

    @Test func anyEditBreaksIdentity() {
        #expect(!VideoExportOptions(rotationDegrees: 90).isIdentity)
        #expect(!VideoExportOptions(trimEnd: 5).isIdentity)
        #expect(!VideoExportOptions(mute: true).isIdentity)
        #expect(!VideoExportOptions(speed: 2).isIdentity)
        #expect(!VideoExportOptions(compression: .high).isIdentity)
    }

    @Test func fullFrameCropIsStillIdentity() {
        let crop = CropRect(x: 0, y: 0, width: 1, height: 1)
        #expect(VideoExportOptions(crop: crop).isIdentity)
    }

    // MARK: trim (input-side -ss / -t)

    @Test func trimStartAndEndSeekInput() {
        let a = args(VideoExportOptions(trimStart: 5, trimEnd: 15))
        #expect(Array(a.prefix(5)) == ["-ss", "5", "-t", "10", "-i"])
    }

    @Test func trimEndOnlyHasDurationNoSeek() {
        let a = args(VideoExportOptions(trimEnd: 8))
        #expect(!a.contains("-ss"))
        #expect(value(after: "-t", in: a) == "8")
    }

    @Test func trimStartOnlyHasSeekNoDuration() {
        let a = args(VideoExportOptions(trimStart: 3))
        #expect(value(after: "-ss", in: a) == "3")
        #expect(!a.contains("-t"))
    }

    // MARK: rotation / flip

    @Test func rotation90Transposes() {
        #expect(value(after: "-vf", in: args(VideoExportOptions(rotationDegrees: 90))) == "transpose=1")
    }

    @Test func rotation180TransposesTwice() {
        let vf = value(after: "-vf", in: args(VideoExportOptions(rotationDegrees: 180)))
        #expect(vf == "transpose=1,transpose=1")
    }

    @Test func rotation270Transposes2() {
        #expect(value(after: "-vf", in: args(VideoExportOptions(rotationDegrees: 270))) == "transpose=2")
    }

    @Test func negativeRotationNormalizes() {
        #expect(value(after: "-vf", in: args(VideoExportOptions(rotationDegrees: -90))) == "transpose=2")
    }

    @Test func flipsEmitHflipVflip() {
        let vf = value(after: "-vf", in: args(VideoExportOptions(flipH: true, flipV: true)))
        #expect(vf == "hflip,vflip")
    }

    // MARK: crop

    @Test func cropUsesInputDimensionExpressions() {
        let crop = CropRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5)
        let vf = value(after: "-vf", in: args(VideoExportOptions(crop: crop)))
        #expect(vf == "crop=iw*0.5:ih*0.5:iw*0.25:ih*0.1")
    }

    @Test func fullFrameCropEmitsNoFilter() {
        let crop = CropRect(x: 0, y: 0, width: 1, height: 1)
        #expect(!args(VideoExportOptions(crop: crop)).contains("-vf"))
    }

    // MARK: scale / speed

    @Test func scaleWidthKeepsAspect() {
        let vf = value(after: "-vf", in: args(VideoExportOptions(scaleWidth: 720)))
        #expect(vf == "scale=720:-2")
    }

    @Test func speedSetsPtsAndAtempo() {
        let a = args(VideoExportOptions(speed: 2))
        #expect(value(after: "-vf", in: a) == "setpts=PTS/2")
        #expect(value(after: "-af", in: a) == "atempo=2")
    }

    @Test func fastSpeedChainsAtempo() {
        #expect(value(after: "-af", in: args(VideoExportOptions(speed: 4))) == "atempo=2,atempo=2")
    }

    @Test func slowSpeedChainsAtempo() {
        #expect(value(after: "-af", in: args(VideoExportOptions(speed: 0.25))) == "atempo=0.5,atempo=0.5")
    }

    // MARK: mute

    @Test func muteDropsAudio() {
        let a = args(VideoExportOptions(mute: true))
        #expect(a.contains("-an"))
        #expect(!a.contains("-c:a"))
    }

    @Test func muteSkipsAudioFilterEvenWithSpeed() {
        let a = args(VideoExportOptions(speed: 2, mute: true))
        #expect(a.contains("-an"))
        #expect(!a.contains("-af"))
        #expect(value(after: "-vf", in: a) == "setpts=PTS/2")
    }

    // MARK: compression

    @Test func compressionMapsToCrf() {
        #expect(value(after: "-crf", in: args(VideoExportOptions(compression: .none))) == "18")
        #expect(value(after: "-crf", in: args(VideoExportOptions(compression: .medium))) == "23")
        #expect(value(after: "-crf", in: args(VideoExportOptions(compression: .high))) == "28")
    }

    // MARK: formats

    @Test func movGetsFaststart() {
        let a = args(VideoExportOptions(format: .mov))
        #expect(a.contains("libx264"))
        #expect(value(after: "-movflags", in: a) == "+faststart")
    }

    @Test func mkvHasNoFaststart() {
        let a = args(VideoExportOptions(format: .mkv))
        #expect(a.contains("libx264"))
        #expect(!a.contains("-movflags"))
    }

    @Test func webmUsesVp9AndOpus() {
        let a = args(VideoExportOptions(format: .webm))
        #expect(a.contains("libvpx-vp9"))
        #expect(a.contains("libopus"))
        #expect(!a.contains("-movflags"))
    }

    @Test func webmMutedHasNoAudioCodec() {
        let a = args(VideoExportOptions(mute: true, format: .webm))
        #expect(a.contains("-an"))
        #expect(!a.contains("libopus"))
    }

    // MARK: gif

    @Test func gifUsesPaletteFilterComplexAndNoAudio() {
        let a = args(VideoExportOptions(format: .gif))
        #expect(a.contains("-an"))
        let complex = value(after: "-filter_complex", in: a)
        #expect(complex?.contains("palettegen") == true)
        #expect(complex?.contains("paletteuse") == true)
        #expect(complex?.contains("scale=480:-1:flags=lanczos") == true)
    }

    @Test func gifAppliesGeometryBeforePalette() {
        let a = args(VideoExportOptions(rotationDegrees: 90, format: .gif))
        let complex = value(after: "-filter_complex", in: a) ?? ""
        #expect(complex.contains("transpose=1"))
        // geometry precedes the fps/scale palette stage
        let t = complex.range(of: "transpose=1")
        let f = complex.range(of: "fps=15")
        #expect(t != nil && f != nil && t!.lowerBound < f!.lowerBound)
    }

    @Test func gifScaleWidthOverridesDefault() {
        let complex = value(after: "-filter_complex", in: args(VideoExportOptions(scaleWidth: 320, format: .gif)))
        #expect(complex?.contains("scale=320:-1:flags=lanczos") == true)
    }

    // MARK: combined ordering

    @Test func filterChainOrderIsCropRotateFlipScaleSpeed() {
        let options = VideoExportOptions(
            rotationDegrees: 90, flipH: true,
            crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5),
            speed: 2, scaleWidth: 640
        )
        let vf = value(after: "-vf", in: args(options))
        #expect(vf == "crop=iw*0.5:ih*0.5:iw*0:ih*0,transpose=1,hflip,scale=640:-2,setpts=PTS/2")
    }
}
