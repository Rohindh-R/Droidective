import Testing
@testable import ADBKit

@Suite struct OverridesServiceTests {
    private func makeService(_ runner: MockProcessRunner) async -> OverridesService {
        OverridesService(client: await makeTestClient(runner: runner), store: makeTempOverridesStore())
    }

    /// Scripts a device with nothing overridden.
    private func scriptCleanDevice(_ runner: MockProcessRunner) {
        runner.script(argsPrefix: ["-s", "S1", "shell", "settings", "get", "global", "http_proxy"], stdout: "null\n")
        runner.script(argsPrefix: ["-s", "S1", "shell", "settings", "get", "system", "font_scale"], stdout: "1.0\n")
        runner.script(argsPrefix: ["-s", "S1", "shell", "wm", "density"], stdout: "Physical density: 420\n")
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "settings", "get", "global", "window_animation_scale"], stdout: "1.0\n"
        )
        runner.script(argsPrefix: ["-s", "S1", "shell", "cmd", "uimode", "night"], stdout: "Night mode: no\n")
    }

    @Test func cleanDeviceHasNoActiveOverrides() async throws {
        let runner = MockProcessRunner()
        scriptCleanDevice(runner)
        let service = await makeService(runner)
        #expect(try await service.active(serial: "S1").isEmpty)
    }

    @Test func proxyDetectedFromDeviceEvenWithoutRecord() async throws {
        let runner = MockProcessRunner()
        scriptCleanDevice(runner)
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "settings", "get", "global", "http_proxy"],
            stdout: "10.0.0.5:8888\n"
        )
        let service = await makeService(runner)
        let active = try await service.active(serial: "S1")
        #expect(active.map(\.kind) == [.proxy])
        #expect(active[0].value == "10.0.0.5:8888")
    }

    @Test func proxySentinelValuesTreatedAsClear() async throws {
        for sentinel in ["null", ":0", ""] {
            let runner = MockProcessRunner()
            scriptCleanDevice(runner)
            runner.script(
                argsPrefix: ["-s", "S1", "shell", "settings", "get", "global", "http_proxy"],
                stdout: sentinel + "\n"
            )
            let service = await makeService(runner)
            #expect(try await service.active(serial: "S1").isEmpty, "sentinel \(sentinel) should be inactive")
        }
    }

    @Test func layoutDetectedFromFontScaleAndDensityOverride() async throws {
        let runner = MockProcessRunner()
        scriptCleanDevice(runner)
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "settings", "get", "system", "font_scale"], stdout: "1.30\n"
        )
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "wm", "density"],
            stdout: "Physical density: 420\nOverride density: 320\n"
        )
        let service = await makeService(runner)
        let active = try await service.active(serial: "S1")
        #expect(active.map(\.kind) == [.layout])
        #expect(active[0].value == "font 1.30× · 320dpi")
    }

    @Test func animationZeroAndNightYesDetected() async throws {
        let runner = MockProcessRunner()
        scriptCleanDevice(runner)
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "settings", "get", "global", "window_animation_scale"], stdout: "0\n"
        )
        runner.script(argsPrefix: ["-s", "S1", "shell", "cmd", "uimode", "night"], stdout: "Night mode: yes\n")
        let service = await makeService(runner)
        let kinds = try await service.active(serial: "S1").map(\.kind)
        #expect(Set(kinds) == Set([.animation, .darkMode]))
    }

    @Test func batteryTrustedFromStore() async throws {
        let runner = MockProcessRunner()
        scriptCleanDevice(runner)
        runner.script(argsPrefix: ["-s", "S1", "shell", "dumpsys", "battery"], stdout: "")
        let service = await makeService(runner)

        let value = try await service.applyBattery(serial: "S1", level: 5, unplugged: true)
        #expect(value == "5% · unplugged")

        let active = try await service.active(serial: "S1")
        #expect(active.map(\.kind) == [.battery])
        #expect(active[0].value == "5% · unplugged")

        try await service.reset(serial: "S1", kind: .battery)
        #expect(try await service.active(serial: "S1").isEmpty)
        #expect(runner.invocations.contains { $0.arguments == ["-s", "S1", "shell", "dumpsys", "battery", "reset"] })
    }

    @Test func proxyResetClearsSettingBothWays() async throws {
        let runner = MockProcessRunner()
        scriptCleanDevice(runner)
        let service = await makeService(runner)

        try await service.reset(serial: "S1", kind: .proxy)
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "settings", "put", "global", "http_proxy", ":0"]
        })
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "settings", "delete", "global", "http_proxy"]
        })
    }

    @Test func demoModeSendsEnterAndExitBroadcasts() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let service = await makeService(runner)

        try await service.applyDemo(serial: "S1", on: true)
        #expect(runner.invocations.contains {
            $0.arguments.starts(with: ["-s", "S1", "shell", "am", "broadcast", "-a", "com.android.systemui.demo", "-e", "command", "enter"])
        })

        try await service.applyDemo(serial: "S1", on: false)
        #expect(runner.invocations.contains {
            $0.arguments == ["-s", "S1", "shell", "am", "broadcast", "-a", "com.android.systemui.demo", "-e", "command", "exit"]
        })
    }
}
