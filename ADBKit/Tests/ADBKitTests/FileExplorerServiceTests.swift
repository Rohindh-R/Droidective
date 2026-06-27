import Testing
@testable import ADBKit

@Suite struct FileExplorerServiceTests {
    private func makeService(_ runner: MockProcessRunner) async -> FileExplorerService {
        FileExplorerService(client: await makeTestClient(runner: runner))
    }

    @Test func cleanSuccessReportsPlainMessage() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "mkdir"], stdout: "", stderr: "", exitCode: 0)
        let result = try await makeService(runner).makeDirectory(serial: "S1", path: "/sdcard/New Folder")
        #expect(result.ok)
        #expect(result.message == "Folder created")
    }

    @Test func zeroExitWithStderrSucceedsWithWarning() async throws {
        // A toybox warning printed on a zero exit (the op still happened) must
        // not be misreported as a failure.
        let runner = MockProcessRunner()
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "cp"],
            stdout: "", stderr: "cp: can't open 'sub': Permission denied", exitCode: 0
        )
        let result = try await makeService(runner).copy(serial: "S1", from: "/a", toDir: "/b")
        #expect(result.ok)
        #expect(result.message.contains("with warnings"))
    }

    @Test func nonZeroExitReportsFailure() async throws {
        let runner = MockProcessRunner()
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "rm"],
            stdout: "", stderr: "rm: No such file or directory", exitCode: 1
        )
        let result = try await makeService(runner).delete(serial: "S1", path: "/missing")
        #expect(!result.ok)
    }

    @Test func devicePathsAreShellQuoted() async throws {
        // Paths with spaces/metacharacters must reach the device shell quoted.
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "mkdir"], stdout: "", exitCode: 0)
        _ = try await makeService(runner).makeDirectory(serial: "S1", path: "/sdcard/a b;c")
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "mkdir", "-p", "'/sdcard/a b;c'"]
        })
    }

    @Test func deletePathIsShellQuoted() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "rm"], stdout: "", exitCode: 0)
        _ = try await makeService(runner).delete(serial: "S1", path: "/sdcard/a b;rm -rf /")
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "rm", "-rf", "'/sdcard/a b;rm -rf /'"]
        })
    }

    @Test func copySourceAndDestinationAreShellQuoted() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "cp"], stdout: "", exitCode: 0)
        _ = try await makeService(runner).copy(serial: "S1", from: "/sdcard/a b", toDir: "/sdcard/c;d")
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "cp", "-r", "'/sdcard/a b'", "'/sdcard/c;d'"]
        })
    }

    @Test func moveSourceAndDestinationAreShellQuoted() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "mv"], stdout: "", exitCode: 0)
        _ = try await makeService(runner).move(serial: "S1", from: "/sdcard/a b", toDir: "/sdcard/c;d")
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "mv", "'/sdcard/a b'", "'/sdcard/c;d'"]
        })
    }
}
