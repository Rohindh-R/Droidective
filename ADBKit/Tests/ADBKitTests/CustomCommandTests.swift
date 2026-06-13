import Testing
@testable import ADBKit

@Suite struct CustomCommandTemplateTests {
    @Test func tokenizesSimpleCommand() throws {
        #expect(try CustomCommandService.tokenize("shell input keyevent 82") == ["shell", "input", "keyevent", "82"])
    }

    @Test func honorsQuotes() throws {
        #expect(try CustomCommandService.tokenize(#"shell am broadcast --es msg "hello world""#)
            == ["shell", "am", "broadcast", "--es", "msg", "hello world"])
        #expect(try CustomCommandService.tokenize("shell echo 'a b'") == ["shell", "echo", "a b"])
    }

    @Test func emptyQuotedTokenSurvives() throws {
        #expect(try CustomCommandService.tokenize(#"shell echo """#) == ["shell", "echo", ""])
    }

    @Test func unbalancedQuoteThrows() {
        #expect(throws: CustomCommandService.TemplateError.unbalancedQuote) {
            _ = try CustomCommandService.tokenize(#"shell echo "oops"#)
        }
    }

    @Test func emptyTemplateThrows() {
        #expect(throws: CustomCommandService.TemplateError.empty) {
            _ = try CustomCommandService.tokenize("   ")
        }
    }

    @Test func substitutesPlaceholders() throws {
        let args = try CustomCommandService.buildArgs(
            template: "shell am force-stop {bundleId}", bundleId: "com.app", serial: "S1"
        )
        #expect(args == ["shell", "am", "force-stop", "com.app"])
    }

    @Test func dropsLeadingAdbToken() throws {
        let args = try CustomCommandService.buildArgs(template: "adb devices", bundleId: nil, serial: "")
        #expect(args == ["devices"])
    }

    @Test func bundlePlaceholderWithoutBundleThrows() {
        #expect(throws: CustomCommandService.TemplateError.missingBundle) {
            _ = try CustomCommandService.buildArgs(template: "shell pm clear {bundleId}", bundleId: nil, serial: "S1")
        }
    }

    @Test func runInjectsSerialWhenAbsent() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell"], stdout: "done")
        let service = CustomCommandService(client: await makeTestClient(runner: runner))
        let command = CustomCommand(name: "Test", command: "shell echo hi", needsBundle: false, createdAt: 0)

        let result = await service.run(command: command, bundleId: nil, serial: "S1")
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "echo", "hi"])
    }
}
