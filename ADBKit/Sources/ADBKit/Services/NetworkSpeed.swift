import Foundation

/// Download/upload throughput for one interface over the last interval, plus
/// its cumulative byte counters.
public struct InterfaceSpeed: Sendable, Equatable, Identifiable {
    public let name: String
    public let downloadBytesPerSec: Double
    public let uploadBytesPerSec: Double
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public var id: String { name }
}

/// One network sample: device-wide download/upload speed (delta over time),
/// the cumulative totals since boot, and a per-interface breakdown.
public struct NetSample: Sendable, Equatable {
    public let downloadBytesPerSec: Double
    public let uploadBytesPerSec: Double
    public let totalRxBytes: UInt64
    public let totalTxBytes: UInt64
    public let interfaces: [InterfaceSpeed]
}

/// Samples `/proc/net/dev` and turns the cumulative byte counters into live
/// throughput by differencing against the previous read (held per serial). The
/// first poll for a serial returns nil (no delta yet).
public actor NetworkSpeedService {
    private let client: AdbClient
    private var previous: [String: (interfaces: [String: (rx: UInt64, tx: UInt64)], at: Date)] = [:]

    public init(client: AdbClient) {
        self.client = client
    }

    public func reset() {
        previous.removeAll()
    }

    public func poll(serial: String) async -> NetSample? {
        guard let output = (try? await client.run(on: serial, ["shell", "cat", "/proc/net/dev"]))?.stdout else {
            return nil
        }
        let now = Date()
        let current = NetDevParser.parseInterfaces(output)
        let currentMap = Dictionary(
            current.map { ($0.name, (rx: $0.rxBytes, tx: $0.txBytes)) },
            uniquingKeysWith: { first, _ in first }
        )
        let totalRx = current.reduce(UInt64(0)) { $0 + $1.rxBytes }
        let totalTx = current.reduce(UInt64(0)) { $0 + $1.txBytes }

        defer { previous[serial] = (currentMap, now) }
        guard let prior = previous[serial] else { return nil }
        let elapsed = now.timeIntervalSince(prior.at)
        guard elapsed > 0 else { return nil }

        var speeds: [InterfaceSpeed] = []
        var totalDown = 0.0
        var totalUp = 0.0
        for interface in current {
            let priorBytes = prior.interfaces[interface.name]
            // &- guards a counter reset; a brand-new interface (no prior) reads 0.
            let down = Double(interface.rxBytes &- (priorBytes?.rx ?? interface.rxBytes)) / elapsed
            let up = Double(interface.txBytes &- (priorBytes?.tx ?? interface.txBytes)) / elapsed
            let clampedDown = max(0, down)
            let clampedUp = max(0, up)
            totalDown += clampedDown
            totalUp += clampedUp
            if priorBytes != nil || clampedDown > 0 || clampedUp > 0 {
                speeds.append(InterfaceSpeed(
                    name: interface.name,
                    downloadBytesPerSec: clampedDown,
                    uploadBytesPerSec: clampedUp,
                    rxBytes: interface.rxBytes,
                    txBytes: interface.txBytes
                ))
            }
        }
        return NetSample(
            downloadBytesPerSec: totalDown,
            uploadBytesPerSec: totalUp,
            totalRxBytes: totalRx,
            totalTxBytes: totalTx,
            interfaces: speeds.sorted {
                ($0.downloadBytesPerSec + $0.uploadBytesPerSec) > ($1.downloadBytesPerSec + $1.uploadBytesPerSec)
            }
        )
    }
}
