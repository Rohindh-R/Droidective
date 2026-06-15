import Testing
@testable import ADBKit

@Suite struct AppControlServiceTests {
    private func makeService(_ runner: MockProcessRunner) async -> AppControlService {
        AppControlService(client: await makeTestClient(runner: runner))
    }

    @Test func openUsesMonkeyLauncher() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "Events injected: 1")
        let service = await makeService(runner)

        let result = try await service.control(serial: "S1", packageId: "com.app", action: .open)
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == [
            "-s", "S1", "shell", "monkey", "-p", "com.app", "-c", "android.intent.category.LAUNCHER", "1",
        ])
    }

    @Test func openDetectsMissingLauncherActivity() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "** No activities found to run, monkey aborted.")
        let service = await makeService(runner)

        let result = try await service.control(serial: "S1", packageId: "com.app", action: .open)
        #expect(!result.ok)
    }

    @Test func destructiveActionsAreFlagged() {
        #expect(AppControlService.AppAction.clearData.isDestructive)
        #expect(AppControlService.AppAction.uninstall.isDestructive)
        #expect(!AppControlService.AppAction.open.isDestructive)
        #expect(!AppControlService.AppAction.clearCache.isDestructive)
    }

    @Test func uninstallChecksForSuccessText() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "uninstall"], stdout: "Failure [DELETE_FAILED_INTERNAL_ERROR]")
        let service = await makeService(runner)

        let result = try await service.control(serial: "S1", packageId: "com.app", action: .uninstall)
        #expect(!result.ok)
    }

    @Test func listsThirdPartyPackagesSorted() async throws {
        let runner = MockProcessRunner()
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "pm", "list", "packages", "-3"],
            stdout: "package:com.zebra\npackage:com.alpha\n\npackage:com.middle\n"
        )
        let service = await makeService(runner)

        let packages = try await service.listInstalledPackages(serial: "S1")
        #expect(packages == ["com.alpha", "com.middle", "com.zebra"])
    }

    @Test func listInstalledPackagesStripsCarriageReturns() async throws {
        // CRLF device-shell output must not leave a trailing \r on package ids,
        // or downstream force-stop/clear/uninstall silently fail to match.
        let runner = MockProcessRunner()
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "pm", "list", "packages", "-3"],
            stdout: "package:com.zebra\r\npackage:com.alpha\r\n"
        )
        let service = await makeService(runner)

        let packages = try await service.listInstalledPackages(serial: "S1")
        #expect(packages == ["com.alpha", "com.zebra"])
        #expect(!packages.contains { $0.contains("\r") })
    }

    @Test func deepLinkLaunchDetectsActivityErrors() async throws {
        let runner = MockProcessRunner()
        runner.script(
            argsPrefix: ["-s"],
            stdout: "Error: Activity not started, unable to resolve Intent"
        )
        let service = await makeService(runner)

        let result = try await service.launchDeepLink(serial: "S1", url: "myapp://home")
        #expect(!result.ok)
    }
}
