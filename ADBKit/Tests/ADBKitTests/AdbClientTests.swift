import Testing
@testable import ADBKit

@Suite struct AdbClientTests {
    @Test func injectsSerialFlag() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "ok")
        let client = await makeTestClient(runner: runner)

        let result = try await client.run(on: "SERIAL1", ["shell", "echo", "hi"])
        #expect(result.succeeded)
        #expect(runner.invocations == [
            .init(executable: "/fake/adb", arguments: ["-s", "SERIAL1", "shell", "echo", "hi"])
        ])
    }

    @Test func nonZeroExitReturnsResultNotError() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["reverse"], stderr: "error: closed", exitCode: 1)
        let client = await makeTestClient(runner: runner)

        let result = try await client.run(["reverse", "tcp:8081", "tcp:8081"])
        #expect(!result.succeeded)
        #expect(result.exitCode == 1)
        #expect(result.stderr == "error: closed")
    }

    @Test func timeoutSurfacesAsTimedOutFlag() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["shell"], exitCode: nil, timedOut: true)
        let client = await makeTestClient(runner: runner)

        let result = try await client.run(["shell", "sleep", "100"])
        #expect(result.timedOut)
        #expect(result.exitCode == nil)
    }

    @Test func missingAdbThrowsNotFound() async {
        let runner = MockProcessRunner()
        let locator = ToolLocator(runner: runner, environment: [:])
        await locator.seed(.adb, path: nil)
        let client = AdbClient(locator: locator, runner: runner, log: CommandLog())

        await #expect(throws: AdbError.adbNotFound) {
            _ = try await client.run(["devices"])
        }
    }

    @Test func runOnAllFansOutPreservingOrder() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "done")
        let client = await makeTestClient(runner: runner)

        let results = try await client.runOnAll(serials: ["A", "B", "C"], ["shell", "true"])
        #expect(results.map(\.serial) == ["A", "B", "C"])
        #expect(results.allSatisfy { $0.result.succeeded })
        #expect(runner.invocations.count == 3)
    }
}

@Suite struct CommandLogTests {
    @Test func recordsOnlyInsideUserInitiatedScope() async {
        let log = CommandLog()
        await log.record(command: "adb devices", exitCode: 0, duration: .zero, stdout: "", stderr: "")
        #expect(await log.snapshot().isEmpty)

        await CommandLog.$isUserInitiated.withValue(true) {
            await log.record(command: "adb shell input keyevent 82", exitCode: 0, duration: .zero, stdout: "", stderr: "")
        }
        let entries = await log.snapshot()
        #expect(entries.count == 1)
        #expect(entries[0].command == "adb shell input keyevent 82")
    }

    @Test func evictsOldestBeyondMax() async {
        let log = CommandLog()
        await CommandLog.$isUserInitiated.withValue(true) {
            for index in 0..<(CommandLog.maxEntries + 5) {
                await log.record(command: "cmd \(index)", exitCode: 0, duration: .zero, stdout: "", stderr: "")
            }
        }
        let entries = await log.snapshot()
        #expect(entries.count == CommandLog.maxEntries)
        #expect(entries.first?.command == "cmd \(CommandLog.maxEntries + 4)")
        #expect(entries.last?.command == "cmd 5")
    }

    @Test func truncatesCapturedOutput() async {
        let log = CommandLog()
        let huge = String(repeating: "x", count: CommandLog.maxCapture + 100)
        await CommandLog.$isUserInitiated.withValue(true) {
            await log.record(command: "c", exitCode: 0, duration: .zero, stdout: huge, stderr: huge)
        }
        let entry = await log.snapshot()[0]
        #expect(entry.stdout.count == CommandLog.maxCapture)
        #expect(entry.stderr.count == CommandLog.maxCapture)
    }
}
