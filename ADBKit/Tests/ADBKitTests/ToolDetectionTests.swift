import Testing
@testable import ADBKit

@Suite struct ToolDetectionTests {
    @Test func detectAllReportsEveryToolWithItsVersion() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: [], stdout: "tool version 1.2.3\ntrailing noise")
        let locator = ToolLocator(runner: runner, environment: [:])
        for tool in Tool.allCases {
            await locator.seed(tool, path: "/usr/local/bin/\(tool.rawValue)")
        }
        let service = ToolDetectionService(locator: locator, runner: runner)

        let report = await service.detectAll()

        #expect(report.count == Tool.allCases.count)
        for tool in Tool.allCases {
            #expect(report[tool]?.installed == true, "\(tool) should be installed")
            #expect(report[tool]?.version == "tool version 1.2.3")
        }
    }

    @Test func detectAllReportsMissingToolsAsNotInstalled() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["version"], stdout: "adb 1.0.41")
        let locator = ToolLocator(runner: runner, environment: [:])
        await locator.seed(.adb, path: "/usr/local/bin/adb")
        for tool in Tool.allCases where tool != .adb {
            await locator.seed(tool, path: nil) // negative cache → no login-shell probe
        }
        let service = ToolDetectionService(locator: locator, runner: runner)

        let report = await service.detectAll()

        #expect(report[.adb]?.installed == true)
        #expect(report[.adb]?.version == "adb 1.0.41")
        #expect(report[.ffmpeg]?.installed == false)
        #expect(report[.emulator]?.installed == false)
        #expect(report[.scrcpy]?.installed == false)
    }
}
