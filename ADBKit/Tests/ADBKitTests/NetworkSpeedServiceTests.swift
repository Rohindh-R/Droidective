import Testing
@testable import ADBKit

@Suite struct NetworkSpeedServiceTests {
    private func makeService(_ runner: MockProcessRunner) async -> NetworkSpeedService {
        NetworkSpeedService(client: await makeTestClient(runner: runner))
    }

    private static func procNetDev(rx: UInt64, tx: UInt64) -> String {
        """
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
          wlan0: \(rx) 900 0 0 0 0 0 0 \(tx) 800 0 0 0 0 0 0
        """
    }

    private func script(_ runner: MockProcessRunner, rx: UInt64, tx: UInt64) {
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "cat", "/proc/net/dev"],
            stdout: Self.procNetDev(rx: rx, tx: tx))
    }

    @Test func firstPollReturnsNilWithNoBaseline() async {
        let runner = MockProcessRunner()
        script(runner, rx: 1000, tx: 500)
        #expect(await makeService(runner).poll(serial: "S1") == nil)
    }

    @Test func secondPollReportsCumulativeTotals() async {
        let runner = MockProcessRunner()
        script(runner, rx: 1000, tx: 500)
        let service = await makeService(runner)
        _ = await service.poll(serial: "S1")  // primes the baseline
        script(runner, rx: 5000, tx: 2000)
        let sample = await service.poll(serial: "S1")
        #expect(sample?.totalRxBytes == 5000)
        #expect(sample?.totalTxBytes == 2000)
        #expect((sample?.downloadBytesPerSec ?? -1) >= 0)
    }

    @Test func counterResetClampsToZeroNotASpike() async {
        let runner = MockProcessRunner()
        script(runner, rx: 1_000_000, tx: 500_000)
        let service = await makeService(runner)
        _ = await service.poll(serial: "S1")
        // Counters went backwards (a reboot) — throughput must read 0, not the
        // huge spike a wrapping subtraction would produce.
        script(runner, rx: 50, tx: 20)
        let sample = await service.poll(serial: "S1")
        #expect(sample?.downloadBytesPerSec == 0)
        #expect(sample?.uploadBytesPerSec == 0)
        #expect(sample?.interfaces.first?.downloadBytesPerSec == 0)
    }

    @Test func resetClearsBaselineSoNextPollIsNilAgain() async {
        let runner = MockProcessRunner()
        script(runner, rx: 1000, tx: 500)
        let service = await makeService(runner)
        _ = await service.poll(serial: "S1")
        await service.reset()
        #expect(await service.poll(serial: "S1") == nil)
    }
}
