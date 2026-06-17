import Testing
@testable import ADBKit

@Suite struct ProcStatParsingTests {
    @Test func parsesAggregateAndPerCore() {
        let output = """
        cpu  1000 0 500 8000 200 0 50 0 0 0
        cpu0 200 0 100 2000 50 0 10 0 0 0
        cpu1 300 0 150 2000 50 0 20 0 0 0
        intr 999999
        """
        let times = ProcStatParser.parse(output)
        #expect(times.count == 3)
        #expect(times[0].core == -1)
        #expect(times[0].idle == 8200)        // idle + iowait
        #expect(times[0].total == 9750)
        #expect(times[1].core == 0)
        #expect(times[2].core == 1)
    }

    @Test func ignoresNonCpuLines() {
        #expect(ProcStatParser.parse("intr 5\nctxt 9\n").isEmpty)
    }

    @Test func usageIsIdleComplementBetweenReads() {
        let previous = [CpuTimes(core: 0, total: 1000, idle: 900)]
        let current = [CpuTimes(core: 0, total: 1100, idle: 950)]
        // total +100, idle +50 → 50% busy
        let loads = ProcStatParser.usage(previous: previous, current: current)
        #expect(loads.count == 1)
        #expect(loads[0].usagePercent == 50)
    }

    @Test func usageClampsAndZeroesOnNoDelta() {
        let same = [CpuTimes(core: -1, total: 500, idle: 400)]
        #expect(ProcStatParser.usage(previous: same, current: same).first?.usagePercent == 0)
    }
}

@Suite struct CpuInfoParsingTests {
    @Test func parsesPerProcessSkippingTotal() {
        let output = """
        Load: 5.6 / 4.3 / 3.2
        CPU usage from 12000ms to 0ms ago:
          25% 1234/com.foo.app: 15% user + 10% kernel
           5% 567/system_server: 2% user + 3% kernel
         100% TOTAL: 40% user + 30% kernel
        """
        let rows = CpuInfoParser.parse(output)
        #expect(rows.count == 2)
        #expect(rows[0].pid == 1234)
        #expect(rows[0].name == "com.foo.app")
        #expect(rows[0].cpuPercent == 25)
        #expect(rows[1].name == "system_server")
    }
}

@Suite struct MemProcParsingTests {
    @Test func parsesPssByProcessAndStopsAtNextSection() {
        let output = """
        Applications Memory Usage (in Kilobytes):
        Total PSS by process:
            250,123K: com.foo.app (pid 1234 / activities)
             80,000K: system_server (pid 567)
             12,345K: com.android.systemui (pid 890)

        Total PSS by OOM adjustment:
             400,000K: Native
        """
        let rows = MemProcParser.parse(output)
        #expect(rows.count == 3)
        #expect(rows[0].pid == 1234)
        #expect(rows[0].pssKb == 250_123)
        #expect(rows[1].name == "system_server")
        #expect(rows[2].pssKb == 12_345)
    }

    @Test func emptyWhenNoSection() {
        #expect(MemProcParser.parse("nothing here").isEmpty)
    }
}

@Suite struct GfxInfoParsingTests {
    @Test func parsesFrameCounters() {
        let output = """
        Stats since: 123456789ns
        Total frames rendered: 5000
        Janky frames: 250 (5.00%)
        50th percentile: 6ms
        """
        let (total, janky) = GfxInfoParser.parse(output)
        #expect(total == 5000)
        #expect(janky == 250)
    }

    @Test func nilWhenAbsent() {
        let (total, janky) = GfxInfoParser.parse("No process found")
        #expect(total == nil)
        #expect(janky == nil)
    }
}

@Suite struct NetDevParsingTests {
    @Test func sumsInterfacesSkippingLoopback() {
        let output = """
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 5000 50 0 0 0 0 0 0 5000 50 0 0 0 0 0 0
          wlan0: 1000000 900 0 0 0 0 0 0 200000 800 0 0 0 0 0 0
          rmnet0: 500000 400 0 0 0 0 0 0 100000 300 0 0 0 0 0 0
        """
        let (rx, tx) = NetDevParser.parse(output)
        #expect(rx == 1_500_000) // wlan0 + rmnet0; loopback skipped
        #expect(tx == 300_000)
    }

    @Test func emptyOnHeaderOnly() {
        let (rx, tx) = NetDevParser.parse("Inter-|   Receive | Transmit\n face |bytes\n")
        #expect(rx == 0)
        #expect(tx == 0)
    }

    @Test func perInterfaceExcludesLoopback() {
        let output = """
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 5000 50 0 0 0 0 0 0 5000 50 0 0 0 0 0 0
          wlan0: 1000000 900 0 0 0 0 0 0 200000 800 0 0 0 0 0 0
        """
        let interfaces = NetDevParser.parseInterfaces(output)
        #expect(interfaces.count == 1)
        #expect(interfaces.first?.name == "wlan0")
        #expect(interfaces.first?.rxBytes == 1_000_000)
        #expect(interfaces.first?.txBytes == 200_000)
    }
}

@Suite struct ProcessMergeTests {
    @Test func mergesCpuAndMemByPidSortedByMemory() {
        let merged = PerformanceService.mergeProcesses(
            cpu: [(pid: 1234, name: "com.foo", cpuPercent: 25)],
            mem: [(pid: 1234, name: "com.foo", pssKb: 250_000), (pid: 567, name: "sys", pssKb: 80_000)]
        )
        #expect(merged.count == 2)
        #expect(merged[0].pid == 1234)
        #expect(merged[0].cpuPercent == 25)
        #expect(merged[0].pssKb == 250_000)
        #expect(merged[1].pid == 567)
        #expect(merged[1].cpuPercent == nil)
    }
}
