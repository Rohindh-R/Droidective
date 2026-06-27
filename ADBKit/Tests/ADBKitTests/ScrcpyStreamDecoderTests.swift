import Foundation
import Testing
@testable import ADBKit

@Suite struct ScrcpyStreamDecoderTests {
    /// Captured live from emulator-5554 (scrcpy 4.0, forward tunnel, video socket,
    /// max_size=800): dummy `0x00` + 64-byte name "sdk_gphone64_arm64" + "h264" +
    /// session meta (flags 0x80000000, 800x500) + first packet (config, 33-byte
    /// SPS/PPS) + the start of the next packet.
    static let fixtureHex = """
    0073646b5f6770686f6e6536345f61726d3634000000000000000000000000000000000000\
    00000000000000000000000000000000000000000000000000000000683236348000000000\
    000320000001f4400000000000000000000021000000016742c0298d680c8107e790808080\
    83c2211a800000000168ce01a835c82000000a42f7ce9400003d730000000165b80004059f\
    daef2ea7f14000400b519515
    """

    static func hexBytes(_ hex: String) -> [UInt8] {
        let clean = hex.filter { !$0.isWhitespace }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let byte = UInt8(clean[i ..< j], radix: 16) else { break }
            out.append(byte)
            i = j
        }
        return out
    }

    @Test func parsesHandshakeAndFirstConfigPacket() {
        let bytes = Self.hexBytes(Self.fixtureHex)
        var decoder = ScrcpyStreamDecoder(tunnelForward: true)
        let events = decoder.consume(Data(bytes))

        #expect(events.count >= 3)
        guard events.count >= 3 else { return }

        #expect(events[0] == .deviceName("sdk_gphone64_arm64"))

        guard case let .videoHeader(codec, codecRaw, width, height, _) = events[1] else {
            Issue.record("expected videoHeader, got \(events[1])")
            return
        }
        #expect(codec == .h264)
        #expect(codecRaw == 0x6832_3634)
        #expect(width == 800)
        #expect(height == 500)

        guard case let .packet(header, payload) = events[2] else {
            Issue.record("expected packet, got \(events[2])")
            return
        }
        #expect(header.isConfig)
        #expect(!header.isKeyFrame)
        #expect(header.payloadSize == 33)
        #expect(payload.count == 33)
        // Annex-B SPS NAL start: 00 00 00 01 67 (NAL type 7).
        #expect(Array(payload.prefix(5)) == [0x00, 0x00, 0x00, 0x01, 0x67])
    }

    @Test func toleratesFieldsSplitAcrossChunks() {
        let bytes = Self.hexBytes(Self.fixtureHex)
        var decoder = ScrcpyStreamDecoder(tunnelForward: true)
        var events: [ScrcpyStreamDecoder.Event] = []
        // One byte at a time — the worst-case split of every field.
        for byte in bytes { events += decoder.consume(Data([byte])) }

        #expect(events.count >= 3)
        guard events.count >= 3 else { return }
        #expect(events[0] == .deviceName("sdk_gphone64_arm64"))
        guard case let .videoHeader(codec, _, width, height, _) = events[1] else {
            Issue.record("expected videoHeader")
            return
        }
        #expect(codec == .h264)
        #expect(width == 800)
        #expect(height == 500)
        guard case let .packet(header, payload) = events[2] else {
            Issue.record("expected packet")
            return
        }
        #expect(header.isConfig)
        #expect(payload.count == 33)
    }

    @Test func waitsForFullPayloadBeforeEmittingPacket() {
        let bytes = Self.hexBytes(Self.fixtureHex)
        var decoder = ScrcpyStreamDecoder(tunnelForward: true)
        // Bytes 0..<93 cover dummy(1)+name(64)+codec(4)+meta(12)+header(12); the
        // 33-byte config payload spans 93..<126.
        let throughHeader = decoder.consume(Data(bytes[0 ..< 93]))
        #expect(throughHeader.count == 2)  // deviceName + videoHeader, no packet yet
        #expect(!throughHeader.contains { if case .packet = $0 { true } else { false } })

        let withPayload = decoder.consume(Data(bytes[93 ..< 126]))
        #expect(withPayload.count == 1)
        guard case let .packet(header, payload) = withPayload[0] else {
            Issue.record("expected the config packet once its payload completes")
            return
        }
        #expect(header.isConfig)
        #expect(header.payloadSize == 33)
        #expect(payload.count == 33)
    }

    @Test func reverseTunnelHasNoLeadingDummyByte() {
        // Same stream minus the forward-mode dummy byte.
        let bytes = Array(Self.hexBytes(Self.fixtureHex).dropFirst())
        var decoder = ScrcpyStreamDecoder(tunnelForward: false)
        let events = decoder.consume(Data(bytes))
        #expect(events.first == .deviceName("sdk_gphone64_arm64"))
    }

    @Test func haltsOnOversizedPacketSize() {
        // dummy + empty 64-byte name + "h264" + session meta (800x500) + a packet
        // header whose size field is an absurd 0xFFFFFFFF, then some payload bytes.
        var bytes: [UInt8] = [0x00]
        bytes += [UInt8](repeating: 0, count: 64)
        bytes += [0x68, 0x32, 0x36, 0x34]                             // "h264"
        bytes += [0x80, 0, 0, 0, 0, 0, 0x03, 0x20, 0, 0, 0x01, 0xF4]  // flags, w=800, h=500
        bytes += [0, 0, 0, 0, 0, 0, 0, 0]                             // ptsFlags
        bytes += [0xFF, 0xFF, 0xFF, 0xFF]                             // absurd size
        bytes += [0x01, 0x02, 0x03, 0x04]
        var decoder = ScrcpyStreamDecoder(tunnelForward: true)
        let events = decoder.consume(Data(bytes))
        // The header parses, but the absurd size must not yield a packet…
        #expect(!events.contains { if case .packet = $0 { true } else { false } })
        // …and the decoder is halted: further bytes yield nothing (not buffered).
        #expect(decoder.consume(Data([UInt8](repeating: 0xAB, count: 4096))).isEmpty)
    }
}
