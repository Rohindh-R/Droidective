import Foundation
import Testing
@testable import ADBKit

/// End-to-end session test against a real device: transport → protocol decode →
/// H.264 decode. Disabled by default; run with `MIRROR_LIVE_TEST=1 swift test`.
@Suite struct MirrorSessionLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    @Test(.enabled(if: liveEnabled))
    func decodesAFrameFromDevice() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)

        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy is not installed")
            return
        }

        let params = ScrcpyServerParams(scid: UInt32.random(in: 1 ... 0x7fff_ffff), maxSize: 800)
        let config = MirrorTransport.Configuration(
            serial: serial, params: params,
            serverVersion: server.version, localJarPath: server.jarPath)
        let session = MirrorSession(adb: adb, config: config)
        let stream = await session.start()

        // First display sample = config + first frame parsed and a CMSampleBuffer built.
        let gotSample = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await _ in stream { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(gotSample)

        // VideoToolbox decodes asynchronously; poll briefly for the first frame.
        var snapshot: MirrorSession.Snapshot?
        for _ in 0 ..< 30 {
            snapshot = await session.snapshot()
            if snapshot != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        await session.stop()

        guard let snapshot else {
            Issue.record("no decoded frame within timeout")
            return
        }
        #expect(snapshot.width > 0)
        #expect(snapshot.height > 0)
    }

    @Test(.enabled(if: liveEnabled))
    func controlSocketConnectsAndVideoStillFlows() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy is not installed")
            return
        }
        // control: true -> the server expects a 2nd socket; video must still flow.
        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff), control: true, maxSize: 800)
        let config = MirrorTransport.Configuration(
            serial: serial, params: params,
            serverVersion: server.version, localJarPath: server.jarPath)
        let session = MirrorSession(adb: adb, config: config)
        let stream = await session.start()

        let gotSample = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await _ in stream { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(gotSample)

        let sender = await session.controlSender()
        #expect(sender != nil)
        // A real BACK press on the device; just confirm sending doesn't crash.
        sender?(.backOrScreenOn(action: .down))
        sender?(.backOrScreenOn(action: .up))

        await session.stop()
    }
}
