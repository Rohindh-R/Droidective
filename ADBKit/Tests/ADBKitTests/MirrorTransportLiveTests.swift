import Foundation
import Testing
@testable import ADBKit

/// End-to-end transport test against a real device. Disabled by default — it
/// pushes the server, opens a tunnel, and connects, so it needs hardware. Run
/// with `MIRROR_LIVE_TEST=1 swift test` (optionally `MIRROR_SERIAL=<serial>`).
@Suite struct MirrorTransportLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    @Test(.enabled(if: liveEnabled))
    func receivesVideoHeaderFromDevice() async throws {
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
        let transport = MirrorTransport(adb: adb, config: config)

        let header = try await withThrowingTaskGroup(of: ScrcpyStreamDecoder.Event?.self) { group in
            group.addTask {
                let stream = try await transport.start()
                var decoder = ScrcpyStreamDecoder(tunnelForward: true)
                for try await chunk in stream {
                    for event in decoder.consume(chunk) {
                        if case .videoHeader = event { return event }
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        await transport.stop()

        guard case let .videoHeader(codec, _, width, height, _) = header else {
            Issue.record("no video header within timeout — connect/handshake failed")
            return
        }
        #expect(codec == .h264)
        #expect(width > 0)
        #expect(height > 0)
    }
}
