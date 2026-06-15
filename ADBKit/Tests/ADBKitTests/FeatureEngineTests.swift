import Testing
@testable import ADBKit

/// Asserts each implemented runner issues exactly the adb arguments the
/// reference implementation does — the regression net for ported features.
@Suite struct FeatureEngineTests {
    private func makeEngine(_ runner: MockProcessRunner) async -> FeatureEngine {
        let client = await makeTestClient(runner: runner)
        return FeatureEngine(
            client: client, locator: client.locator, monitor: DeviceMonitor(client: client),
            overridesStore: makeTempOverridesStore()
        )
    }

    @Test func devMenuSendsKeyevent82() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "open-dev-menu", serial: "S1", params: [:])
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "input", "keyevent", "82"])
    }

    @Test func reloadJsSendsDoubleKeyevent46() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "reload-js", serial: "S1", params: [:])
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "input", "keyevent", "46", "46"])
    }

    @Test func reversePortValidatesAndRuns() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let bad = await engine.run(featureID: "reverse-port", serial: "S1", params: ["port": .string("99999")])
        #expect(!bad.ok)
        #expect(bad.message == "Enter a valid port (1–65535).")
        #expect(runner.invocations.isEmpty)

        let good = await engine.run(featureID: "reverse-port", serial: "S1", params: ["port": .string("8081")])
        #expect(good.ok)
        #expect(good.message == "Reversed port 8081")
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "reverse", "tcp:8081", "tcp:8081"])
    }

    @Test func disconnectAllOmitsTarget() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["disconnect"], stdout: "")
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\n")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "disconnect", serial: "", params: [:])
        #expect(result.ok)
        #expect(result.message == "Disconnected all wireless devices")
        #expect(runner.invocations.contains { $0.arguments == ["disconnect"] })
    }

    @Test func disconnectWithTargetPassesIt() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["disconnect"], stdout: "")
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\n")
        let engine = await makeEngine(runner)

        let result = await engine.run(
            featureID: "disconnect", serial: "", params: ["target": .string("192.168.1.42:5555")]
        )
        #expect(result.message == "Disconnected 192.168.1.42:5555")
        #expect(runner.invocations.contains { $0.arguments == ["disconnect", "192.168.1.42:5555"] })
    }

    @Test func getIpParsesWlanThenFallsBackToRoute() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "ip", "-f"], stdout: "wlan0: no address")
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "ip", "route"],
            stdout: "default via 192.168.1.1 dev wlan0 src 10.1.2.3"
        )
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "get-ip", serial: "S1", params: [:])
        #expect(result.ok)
        #expect(result.copyText == "10.1.2.3")
    }

    @Test func sendTextAsciiUsesInputText() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "send-text", serial: "S1", params: ["text": .string("hi there")])
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "input", "text", "hi%sthere"])
    }

    @Test func sendTextUnicodeWithoutAdbKeyboardFails() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "ime", "list"], stdout: "com.google.android.inputmethod.latin/.IME")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "send-text", serial: "S1", params: ["text": .string("héllo")])
        #expect(!result.ok)
        #expect(result.message.contains("ADBKeyboard"))
    }

    @Test func networkTogglesReportsSuccessWhenAllCommandsSucceed() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(
            featureID: "network-toggles", serial: "S1",
            params: ["wifi": .bool(false), "data": .bool(true), "airplane": .bool(false)]
        )
        #expect(result.ok)
        #expect(result.message.contains("Wi-Fi off"))
    }

    @Test func networkTogglesReportsFailureInsteadOfFalseSuccess() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        // `svc data disable` is rejected on this ROM.
        runner.script(argsPrefix: ["-s", "S1", "shell", "svc", "data"], stderr: "Permission denial", exitCode: 1)
        let engine = await makeEngine(runner)

        let result = await engine.run(
            featureID: "network-toggles", serial: "S1",
            params: ["wifi": .bool(true), "data": .bool(false), "airplane": .bool(false)]
        )
        #expect(!result.ok)
        #expect(result.message.contains("data"))
    }

    @Test func unimplementedFeatureReportsPlaceholder() async {
        let runner = MockProcessRunner()
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "logcat", serial: "S1", params: [:])
        #expect(!result.ok)
        #expect(result.message.contains("isn't implemented yet"))
    }
}

@Suite struct FeatureRegistryTests {
    @Test func hasAll37Features() {
        #expect(FeatureRegistry.all.count == 37)
        #expect(FeatureRegistry.byID.count == 37)
    }

    @Test func exactly14DefaultEnabled() {
        #expect(FeatureRegistry.defaultEnabledIDs.count == 14)
        let expected: Set<String> = [
            "send-text", "get-ip", "reverse-port", "disconnect",
            "open-dev-menu", "reload-js", "deep-link", "scrcpy", "screenshot",
            "app-management", "logcat", "file-explorer", "apps", "emulators",
        ]
        #expect(Set(FeatureRegistry.defaultEnabledIDs) == expected)
    }

    @Test func everyFeatureHasAHowToNote() {
        for feature in FeatureRegistry.all {
            #expect(FeatureRegistry.howTo(for: feature.id) != nil, "missing howTo for \(feature.id)")
        }
    }

    @Test func searchMatchesKeywordsAndTitle() {
        let logcat = FeatureRegistry.byID["logcat"]!
        #expect(logcat.matches("logs"))
        #expect(logcat.matches("LOGCAT"))
        #expect(!logcat.matches("battery"))
    }

    @Test func layoutDefaultsExposeEnabledSet() {
        let layout = LayoutState()
        #expect(layout.effectiveEnabledIDs.contains("send-text"))
        #expect(layout.effectiveEnabledIDs.contains("custom-commands"))
        #expect(!layout.effectiveEnabledIDs.contains("fake-battery"))
    }
}
