import Foundation

/// Device discovery: polls `adb devices -l`, caches briefly so rapid UI calls
/// don't spawn a process each, and pushes changes to subscribers.
public actor DeviceMonitor {
    private static let cacheTTL: Duration = .seconds(2)

    private let client: AdbClient
    private var cache: (devices: [Device], at: ContinuousClock.Instant)?
    private var continuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]
    private var pollTask: Task<Void, Never>?
    private var lastPublished: [Device]?

    public init(client: AdbClient) {
        self.client = client
    }

    /// List attached devices (USB + wireless), using a short-lived cache.
    public func list(force: Bool = false) async -> [Device] {
        if !force, let cache, ContinuousClock().now - cache.at < Self.cacheTTL {
            return cache.devices
        }
        guard let result = try? await client.run(["devices", "-l"]) else { return [] }
        let devices = DeviceListParser.parse(result.stdout)
        cache = (devices, ContinuousClock().now)
        return devices
    }

    /// Invalidate the cache (call after connect/disconnect/pair) and refresh
    /// subscribers immediately.
    public func invalidate() async {
        cache = nil
        await pollOnce()
    }

    /// Continuous device-list updates; yields whenever the list changes.
    /// Starts the 2s polling loop on first subscription.
    public func updates(interval: Duration = .seconds(2)) -> AsyncStream<[Device]> {
        let id = UUID()
        let stream = AsyncStream<[Device]> { continuation in
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
            self.continuations[id] = continuation
            if let lastPublished {
                continuation.yield(lastPublished)
            }
        }
        startPollingIfNeeded(interval: interval)
        return stream
    }

    private func startPollingIfNeeded(interval: Duration) {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func pollOnce() async {
        let devices = await list(force: true)
        if devices != lastPublished {
            lastPublished = devices
            for continuation in continuations.values {
                continuation.yield(devices)
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
        if continuations.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
