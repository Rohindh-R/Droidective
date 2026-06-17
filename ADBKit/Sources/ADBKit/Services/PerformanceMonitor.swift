import Foundation

// MARK: - Models

/// Per-core CPU utilization for one sample. `core == -1` is the aggregate
/// ("cpu" line); 0…n are the individual cores ("cpu0"…).
public struct CpuCoreLoad: Sendable, Equatable, Identifiable {
    public let core: Int
    public let usagePercent: Double
    public var id: Int { core }
    public var label: String { core < 0 ? "All cores" : "Core \(core)" }

    public init(core: Int, usagePercent: Double) {
        self.core = core
        self.usagePercent = usagePercent
    }
}

/// One process's live resource use. `cpuPercent`/`pssKb` are nil when the
/// source command didn't report that process.
public struct ProcessLoad: Sendable, Equatable, Identifiable {
    public let pid: Int
    public let name: String
    public let cpuPercent: Double?
    public let pssKb: Int?
    public var id: Int { pid }

    public init(pid: Int, name: String, cpuPercent: Double?, pssKb: Int?) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.pssKb = pssKb
    }
}

/// Rendered-frame stats for the watched app over one interval.
public struct FpsStat: Sendable, Equatable {
    public let fps: Double
    /// Percent of frames that missed the deadline this interval (nil if no
    /// frames were drawn).
    public let jankPercent: Double?

    public init(fps: Double, jankPercent: Double?) {
        self.fps = fps
        self.jankPercent = jankPercent
    }
}

/// Raw per-core jiffie counters from one `/proc/stat` read.
public struct CpuTimes: Sendable, Equatable {
    public let core: Int
    public let total: UInt64
    public let idle: UInt64
}

// MARK: - Parsers (pure)

/// `/proc/stat` → per-core jiffie counters, and the per-core utilization
/// between two reads (CPU% is meaningless from a single read).
public enum ProcStatParser {
    public static func parse(_ output: String) -> [CpuTimes] {
        var result: [CpuTimes] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let label = fields.first, label.hasPrefix("cpu") else { continue }
            let suffix = label.dropFirst(3)
            let core: Int
            if suffix.isEmpty {
                core = -1
            } else if let parsed = Int(suffix) {
                core = parsed
            } else {
                continue
            }
            let numbers = fields.dropFirst().compactMap { UInt64($0) }
            guard numbers.count >= 5 else { continue }
            // user nice system idle iowait irq softirq steal …
            let idle = numbers[3] + numbers[4]
            let total = numbers.reduce(0, +)
            result.append(CpuTimes(core: core, total: total, idle: idle))
        }
        return result
    }

    public static func usage(previous: [CpuTimes], current: [CpuTimes]) -> [CpuCoreLoad] {
        let previousByCore = Dictionary(previous.map { ($0.core, $0) }, uniquingKeysWith: { first, _ in first })
        var loads: [CpuCoreLoad] = []
        for sample in current {
            guard let prior = previousByCore[sample.core] else { continue }
            let totalDelta = Double(sample.total &- prior.total)
            let idleDelta = Double(sample.idle &- prior.idle)
            let usage = totalDelta > 0 ? (1 - idleDelta / totalDelta) * 100 : 0
            loads.append(CpuCoreLoad(core: sample.core, usagePercent: min(100, max(0, usage))))
        }
        return loads.sorted { $0.core < $1.core }
    }
}

/// `dumpsys cpuinfo` → per-process CPU%. Lines look like
/// `  12% 1234/com.foo: 8% user + 3% kernel`.
public enum CpuInfoParser {
    public static func parse(_ output: String) -> [(pid: Int, name: String, cpuPercent: Double)] {
        var rows: [(Int, String, Double)] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            // e.g. "  25% 1234/com.foo.app: 15% user + 10% kernel"
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let percentEnd = line.firstIndex(of: "%") else { continue }
            let percentText = line[..<percentEnd].replacingOccurrences(of: "+", with: "")
            guard let percent = Double(percentText) else { continue }
            let rest = line[line.index(after: percentEnd)...].trimmingCharacters(in: .whitespaces)
            // "1234/com.foo.app: …" — the TOTAL line has no pid/ and is skipped.
            guard let slash = rest.firstIndex(of: "/"),
                  let colon = rest[slash...].firstIndex(of: ":"),
                  let pid = Int(rest[..<slash]) else { continue }
            let name = String(rest[rest.index(after: slash)..<colon])
            rows.append((pid, name, percent))
        }
        return rows
    }
}

/// `dumpsys meminfo` → per-process PSS from the "Total PSS by process" block.
/// Lines look like `   123,456K: com.foo (pid 1234 / activities)`.
public enum MemProcParser {
    public static func parse(_ output: String) -> [(pid: Int, name: String, pssKb: Int)] {
        var rows: [(Int, String, Int)] = []
        var inSection = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            if rawLine.contains("Total PSS by process") {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if rawLine.contains("Total PSS by ") { break }
            // e.g. "   250,123K: com.foo (pid 1234 / activities)"
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let kColon = line.range(of: "K:"),
                  let pidMark = line.range(of: "(pid ") else { continue }
            let pssKb = Int(line[..<kColon.lowerBound].filter(\.isNumber)) ?? 0
            let name = line[kColon.upperBound..<pidMark.lowerBound].trimmingCharacters(in: .whitespaces)
            let pidDigits = line[pidMark.upperBound...].prefix { $0.isNumber }
            guard let pid = Int(pidDigits), !name.isEmpty else { continue }
            rows.append((pid, name, pssKb))
        }
        return rows
    }
}

/// `/proc/net/dev` → summed received/transmitted bytes across real interfaces
/// (loopback excluded). Throughput is the delta over time, computed by the
/// service.
public enum NetDevParser {
    public struct Interface: Sendable, Equatable, Identifiable {
        public let name: String
        public let rxBytes: UInt64
        public let txBytes: UInt64
        public var id: String { name }
    }

    public static func parseInterfaces(_ output: String) -> [Interface] {
        var interfaces: [Interface] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "lo" else { continue }
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            // Receive: bytes packets errs drop fifo frame compressed multicast (8),
            // then Transmit: bytes … — so RX = field 0, TX = field 8.
            guard fields.count >= 9, let rx = UInt64(fields[0]), let tx = UInt64(fields[8]) else { continue }
            interfaces.append(Interface(name: name, rxBytes: rx, txBytes: tx))
        }
        return interfaces
    }

    public static func parse(_ output: String) -> (rxBytes: UInt64, txBytes: UInt64) {
        let interfaces = parseInterfaces(output)
        return (interfaces.reduce(0) { $0 + $1.rxBytes }, interfaces.reduce(0) { $0 + $1.txBytes })
    }
}

/// `dumpsys gfxinfo <pkg>` → cumulative frame counters; FPS is their delta
/// over wall-clock time, computed by the service.
public enum GfxInfoParser {
    public static func parse(_ output: String) -> (totalFrames: Int?, jankyFrames: Int?) {
        func firstNumber(after marker: String) -> Int? {
            guard let range = output.range(of: marker) else { return nil }
            let digits = output[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        return (firstNumber(after: "Total frames rendered:"), firstNumber(after: "Janky frames:"))
    }
}

// MARK: - Service

/// Samples device performance counters over adb. CPU-per-core and FPS are
/// deltas against the previous poll for the same serial/package (held here),
/// so the first poll returns no cores / no FPS.
public actor PerformanceService {
    private let client: AdbClient
    private var previousCpu: [String: [CpuTimes]] = [:]
    private var previousGfx: [String: (total: Int, janky: Int, at: Date)] = [:]
    private var previousNet: [String: (rx: UInt64, tx: UInt64, at: Date)] = [:]

    public init(client: AdbClient) {
        self.client = client
    }

    /// One performance sample. `packageId` adds the app's FPS and PSS;
    /// `includeProcesses` adds the (heavier) per-process CPU + RAM table.
    public struct PerfPoll: Sendable, Equatable {
        public var cores: [CpuCoreLoad] = []
        public var ramTotalKb: Int?
        public var ramUsedKb: Int?
        public var appFps: FpsStat?
        public var appPssKb: Int?
        public var downloadBytesPerSec: Double?
        public var uploadBytesPerSec: Double?
        public var processes: [ProcessLoad] = []
    }

    public func poll(serial: String, packageId: String?, includeProcesses: Bool) async -> PerfPoll {
        async let statString = shell(serial, ["cat", "/proc/stat"])
        async let memString = shell(serial, ["cat", "/proc/meminfo"])
        async let netString = shell(serial, ["cat", "/proc/net/dev"])

        var poll = PerfPoll()
        if let stat = await statString {
            let current = ProcStatParser.parse(stat)
            if let previous = previousCpu[serial], !previous.isEmpty {
                poll.cores = ProcStatParser.usage(previous: previous, current: current)
            }
            previousCpu[serial] = current
        }
        if let mem = await memString {
            let (total, available) = DeviceOverview.parseMeminfo(mem)
            poll.ramTotalKb = total
            if let total, let available { poll.ramUsedKb = total - available }
        }
        if let net = await netString, let speed = consumeNet(serial: serial, output: net) {
            poll.downloadBytesPerSec = speed.down
            poll.uploadBytesPerSec = speed.up
        }

        if let packageId, !packageId.isEmpty {
            async let gfxString = shell(serial, ["dumpsys", "gfxinfo", packageId])
            async let appMemString = shell(serial, ["dumpsys", "meminfo", packageId])
            if let gfx = await gfxString {
                poll.appFps = consumeGfx(serial: serial, packageId: packageId, output: gfx)
            }
            if let appMem = await appMemString {
                poll.appPssKb = AppInspectionService.parseMemInfo(appMem).totalPssKb
            }
        }

        if includeProcesses {
            async let cpuString = shell(serial, ["dumpsys", "cpuinfo"])
            async let memProcString = shell(serial, ["dumpsys", "meminfo"])
            let cpuRows = (await cpuString).map(CpuInfoParser.parse) ?? []
            let memRows = (await memProcString).map(MemProcParser.parse) ?? []
            poll.processes = Self.mergeProcesses(cpu: cpuRows, mem: memRows)
        }
        return poll
    }

    /// Forget the delta baselines so a fresh recording doesn't show a spike
    /// computed against a stale, long-ago reading.
    public func reset() {
        previousCpu.removeAll()
        previousGfx.removeAll()
        previousNet.removeAll()
    }

    private func consumeNet(serial: String, output: String) -> (down: Double, up: Double)? {
        let (rx, tx) = NetDevParser.parse(output)
        let now = Date()
        defer { previousNet[serial] = (rx, tx, now) }
        guard let previous = previousNet[serial] else { return nil }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return nil }
        // &- guards the counter resetting (interface down) to a smaller value.
        let down = Double(rx &- previous.rx) / elapsed
        let up = Double(tx &- previous.tx) / elapsed
        return (max(0, down), max(0, up))
    }

    private func consumeGfx(serial: String, packageId: String, output: String) -> FpsStat? {
        let (total, janky) = GfxInfoParser.parse(output)
        guard let total else { return nil }
        let key = "\(serial)|\(packageId)"
        let now = Date()
        defer { previousGfx[key] = (total, janky ?? 0, now) }
        guard let previous = previousGfx[key] else { return nil }
        let framesDelta = max(0, total - previous.total)
        let jankyDelta = max(0, (janky ?? 0) - previous.janky)
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return nil }
        let jankPercent = framesDelta > 0 ? Double(jankyDelta) / Double(framesDelta) * 100 : nil
        return FpsStat(fps: Double(framesDelta) / elapsed, jankPercent: jankPercent)
    }

    static func mergeProcesses(
        cpu: [(pid: Int, name: String, cpuPercent: Double)],
        mem: [(pid: Int, name: String, pssKb: Int)]
    ) -> [ProcessLoad] {
        var byPid: [Int: ProcessLoad] = [:]
        for row in cpu {
            byPid[row.pid] = ProcessLoad(pid: row.pid, name: row.name, cpuPercent: row.cpuPercent, pssKb: nil)
        }
        for row in mem {
            let existing = byPid[row.pid]
            byPid[row.pid] = ProcessLoad(
                pid: row.pid,
                name: existing?.name ?? row.name,
                cpuPercent: existing?.cpuPercent,
                pssKb: row.pssKb
            )
        }
        return byPid.values.sorted {
            ($0.pssKb ?? 0, $0.cpuPercent ?? 0) > ($1.pssKb ?? 0, $1.cpuPercent ?? 0)
        }
    }

    private func shell(_ serial: String, _ args: [String]) async -> String? {
        (try? await client.run(on: serial, ["shell"] + args))?.stdout
    }
}
