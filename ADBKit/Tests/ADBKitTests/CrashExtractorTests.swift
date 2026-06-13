import Testing
@testable import ADBKit

@Suite struct CrashExtractorTests {
    @Test func extractsLastCrashBlock() {
        let log = """
        06-12 10:00:00.000  1  1 I Boring: nothing
        06-12 10:00:01.000  2  2 I Boring: still nothing
        06-12 10:00:02.000  3  3 E AndroidRuntime: FATAL EXCEPTION: main
        06-12 10:00:02.001  3  3 E AndroidRuntime: java.lang.NullPointerException
        06-12 10:00:02.002  3  3 E AndroidRuntime:   at com.app.Main.run(Main.java:10)
        """
        let block = CrashExtractor.extractLastCrash(log)
        // Pre-context is anchored to the LAST crash-marker line, so the
        // block starts two lines above it — the FATAL EXCEPTION line here.
        #expect(block.hasPrefix("06-12 10:00:02.000"))
        #expect(block.contains("FATAL EXCEPTION"))
        #expect(block.contains("NullPointerException"))
        #expect(!block.contains("nothing"))
    }

    @Test func noCrashYieldsEmpty() {
        #expect(CrashExtractor.extractLastCrash("06-12 10:00:00.000 1 1 I Tag: all good").isEmpty)
    }

    @Test func formatsForDestinations() {
        #expect(CrashExtractor.format("boom", as: .slack) == "```\nboom\n```")
        #expect(CrashExtractor.format("boom", as: .jira) == "{code}\nboom\n{code}")
        #expect(CrashExtractor.format("boom", as: .plain) == "boom")
    }

    @Test func crashBufferPreferredOverMainScan() async throws {
        let runner = MockProcessRunner()
        runner.script(
            argsPrefix: ["-s", "S1", "logcat", "-d", "-b", "crash"],
            stdout: "FATAL EXCEPTION: main\nat com.app.Crash"
        )
        let extractor = CrashExtractor(client: await makeTestClient(runner: runner))

        let crash = try await extractor.lastCrash(serial: "S1", format: .plain)
        #expect(crash == "FATAL EXCEPTION: main\nat com.app.Crash")
        // Main buffer never queried.
        #expect(!runner.invocations.contains { $0.arguments.contains("main") })
    }

    @Test func fallsBackToMainBufferWhenCrashBufferEmpty() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "logcat", "-d", "-b", "crash"], stdout: "\n")
        runner.script(
            argsPrefix: ["-s", "S1", "logcat", "-d", "-b", "main"],
            stdout: "I Boring: x\nE ReactNativeJS: TypeError: boom\nE ReactNativeJS: stack line"
        )
        let extractor = CrashExtractor(client: await makeTestClient(runner: runner))

        let crash = try await extractor.lastCrash(serial: "S1", format: .plain)
        #expect(crash?.contains("TypeError: boom") == true)
    }

    @Test func noCrashAnywhereReturnsNil() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "logcat", "-d", "-b", "crash"], stdout: "")
        runner.script(argsPrefix: ["-s", "S1", "logcat", "-d", "-b", "main"], stdout: "I Tag: fine")
        let extractor = CrashExtractor(client: await makeTestClient(runner: runner))

        #expect(try await extractor.lastCrash(serial: "S1", format: .plain) == nil)
    }
}
