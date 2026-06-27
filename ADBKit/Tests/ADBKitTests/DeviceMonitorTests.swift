import Testing
@testable import ADBKit

@Suite struct DeviceMonitorTests {
    private func makeMonitor(_ runner: MockProcessRunner) async -> DeviceMonitor {
        DeviceMonitor(client: await makeTestClient(runner: runner))
    }

    @Test func listCachesWithinTTLAndForceRefetches() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\nABC123 device\n")
        let monitor = await makeMonitor(runner)

        let first = await monitor.list()
        #expect(first.count == 1)
        #expect(first.first?.serial == "ABC123")

        // Output changes, but a cached list() (within the 2s TTL) must not re-fetch.
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\n")
        #expect(await monitor.list().count == 1)
        #expect(await monitor.list(force: true).isEmpty)
    }

    @Test func updatesYieldsInitialThenChangeOnInvalidate() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\nABC123 device\n")
        let monitor = await makeMonitor(runner)

        // A long interval so the poll loop fires once on subscription and then
        // effectively never again — invalidate() drives the subsequent poll.
        var iterator = await monitor.updates(interval: .seconds(3600)).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.count == 1)
        #expect(first?.first?.serial == "ABC123")

        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\nABC123 device\nXYZ789 device\n")
        await monitor.invalidate()
        let second = await iterator.next()
        #expect(second?.count == 2)
    }

    @Test func identicalPollDoesNotYieldButAChangeDoes() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\nABC123 device\n")
        let monitor = await makeMonitor(runner)
        var iterator = await monitor.updates(interval: .seconds(3600)).makeAsyncIterator()
        #expect(await iterator.next()?.count == 1)

        // Same list → no yield from invalidate; then a real change → a yield.
        await monitor.invalidate()
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\n")
        await monitor.invalidate()
        #expect(await iterator.next()?.isEmpty == true)
    }
}
