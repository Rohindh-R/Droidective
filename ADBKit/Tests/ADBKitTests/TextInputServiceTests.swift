import Testing
@testable import ADBKit

@Suite struct TextInputServiceTests {
    @Test func asciiTextUsesInputTextWithEscaping() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "input", "text"], stdout: "", exitCode: 0)
        let service = TextInputService(client: await makeTestClient(runner: runner))
        let result = try await service.send(serial: "S1", text: "hello world")
        #expect(result.ok)
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "input", "text", "hello%sworld"]
        })
    }

    @Test func newlineRoutesAwayFromRawInputText() async throws {
        // A newline must never reach `input text`, where the device shell would
        // treat it as a command separator. Such text routes through the base64
        // IME path, which prompts for ADBKeyboard when it isn't installed.
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "ime", "list"], stdout: "")
        let service = TextInputService(client: await makeTestClient(runner: runner))
        let result = try await service.send(serial: "S1", text: "ok\nrm -rf /")
        #expect(!result.ok)
        #expect(result.needsAdbKeyboard)
        #expect(!runner.invocations.contains { $0.arguments.contains("input") })
    }
}
