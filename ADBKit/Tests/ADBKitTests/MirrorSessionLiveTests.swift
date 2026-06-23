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

    @Test(.enabled(if: liveEnabled))
    func audioSocketDeliversRawPcmWhileVideoFlows() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy is not installed")
            return
        }
        // audio + control on -> the server expects 3 sockets in order
        // (video, audio, control); video must still flow and PCM must arrive.
        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff),
            audio: true, control: true, maxSize: 800)
        let config = MirrorTransport.Configuration(
            serial: serial, params: params,
            serverVersion: server.version, localJarPath: server.jarPath)
        let session = MirrorSession(adb: adb, config: config)
        let stream = await session.start()

        // Video still flows with the audio socket inserted before control.
        let gotVideo = try await withThrowingTaskGroup(of: Bool.self) { group in
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
        #expect(gotVideo)

        // The device (Android 11+) sends PCM even when silent; expect a chunk.
        let gotAudio = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard let audio = await session.audioPCM() else { return false }
                for await chunk in audio where !chunk.isEmpty { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(gotAudio)

        await session.stop()
    }
}

@Suite struct MirrorVolumeLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    private func mediaVolume(_ adb: AdbClient, _ serial: String) async -> Int? {
        let out = try? await adb.run(
            on: serial, ["shell", "cmd", "media_session", "volume", "--stream", "3", "--get"])
        guard let text = out?.stdout, let range = text.range(of: "volume is ") else { return nil }
        let rest = text[range.upperBound...].prefix { $0.isNumber }
        return Int(rest)
    }

    @Test(.enabled(if: liveEnabled))
    func volumeDownKeycodeLowersDeviceVolume() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy not installed"); return
        }

        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff), control: true, maxSize: 800)
        let config = MirrorTransport.Configuration(
            serial: serial, params: params, serverVersion: server.version, localJarPath: server.jarPath)
        let session = MirrorSession(adb: adb, config: config)
        let stream = await session.start()
        let drain = Task { do { for try await _ in stream {} } catch {} }
        for _ in 0 ..< 60 {
            if await session.currentDimensions() != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let sender = await session.controlSender()
        #expect(sender != nil)

        // Media volume starts high; press device VOLUME_DOWN (25) several times
        // over the control channel and confirm the device's own volume drops.
        let before = await mediaVolume(adb, serial)
        for _ in 0 ..< 8 {
            sender?(.injectKeycode(action: .down, keycode: 25, repeatCount: 0, metaState: 0))
            sender?(.injectKeycode(action: .up, keycode: 25, repeatCount: 0, metaState: 0))
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(400))
        let after = await mediaVolume(adb, serial)

        drain.cancel()
        await session.stop()

        print("VOLUME DIAGNOSTIC: before=\(before ?? -1) after=\(after ?? -1)")
        if let before, let after, before > 0 { #expect(after < before) }
    }
}
