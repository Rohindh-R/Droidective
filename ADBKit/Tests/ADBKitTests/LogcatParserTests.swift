import Testing
@testable import ADBKit

@Suite struct LogcatLineParserTests {
    @Test func parsesThreadtimeLine() {
        let line = LogcatLineParser.parse(
            "06-12 14:03:22.123  1234  5678 E ReactNativeJS: TypeError: undefined is not a function"
        )
        #expect(line.time == "06-12 14:03:22.123")
        #expect(line.pid == "1234")
        #expect(line.level == "E")
        #expect(line.tag == "ReactNativeJS")
        #expect(line.message == "TypeError: undefined is not a function")
    }

    @Test func parsesEmptyMessage() {
        let line = LogcatLineParser.parse("06-12 14:03:22.123  1234  5678 D MyTag: ")
        #expect(line.level == "D")
        #expect(line.tag == "MyTag")
        #expect(line.message == "")
    }

    @Test func malformedLineFallsBackToRaw() {
        let raw = "--------- beginning of main"
        let line = LogcatLineParser.parse(raw)
        #expect(line.level == "")
        #expect(line.message == raw)
        #expect(line.raw == raw)
    }

    @Test func tagWithColonInMessageParses() {
        let line = LogcatLineParser.parse("06-12 14:03:22.123  1 2 I Tag: key: value")
        #expect(line.tag == "Tag")
        #expect(line.message == "key: value")
    }

    @Test func buildsArgsWithAllFilters() {
        let filters = LogcatFilters(tail: 100, buffers: ["crash"], level: "W", pid: 4242)
        let args = LogcatLineParser.buildArgs(serial: "S1", filters: filters)
        #expect(args == ["-s", "S1", "logcat", "-v", "threadtime", "-T", "100", "-b", "crash", "--pid", "4242", "*:W"])
    }

    @Test func buildsMinimalArgs() {
        let args = LogcatLineParser.buildArgs(serial: "S1", filters: LogcatFilters())
        #expect(args == ["-s", "S1", "logcat", "-v", "threadtime", "-T", "300"])
    }
}
