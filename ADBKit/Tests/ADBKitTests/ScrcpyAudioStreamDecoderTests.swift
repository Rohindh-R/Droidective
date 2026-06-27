import Foundation
import Testing
@testable import ADBKit

@Suite struct ScrcpyAudioStreamDecoderTests {
    /// codec "raw" (00 72 61 77) + one packet: header (pts=0x10, no flags, size=4)
    /// then 4 bytes of PCM (two s16le frames worth: 01 00 02 00).
    static let rawFixture: [UInt8] = [
        0x00, 0x72, 0x61, 0x77,  // "raw"
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,  // pts/flags = 0x10
        0x00, 0x00, 0x00, 0x04,  // size = 4
        0x01, 0x00, 0x02, 0x00,  // payload
    ]

    @Test func parsesRawCodecThenPacket() {
        var decoder = ScrcpyAudioStreamDecoder()
        let events = decoder.consume(Data(Self.rawFixture))

        #expect(events.count == 2)
        guard events.count == 2 else { return }
        #expect(events[0] == .codec(.raw, codecRaw: 0x0072_6177))

        guard case let .packet(header, payload) = events[1] else {
            Issue.record("expected packet, got \(events[1])")
            return
        }
        #expect(!header.isConfig)
        #expect(!header.isKeyFrame)
        #expect(header.pts == 0x10)
        #expect(header.payloadSize == 4)
        #expect(Array(payload) == [0x01, 0x00, 0x02, 0x00])
    }

    @Test func toleratesByteAtATime() {
        var decoder = ScrcpyAudioStreamDecoder()
        var events: [ScrcpyAudioStreamDecoder.Event] = []
        for byte in Self.rawFixture { events += decoder.consume(Data([byte])) }

        #expect(events.count == 2)
        guard events.count == 2 else { return }
        #expect(events[0] == .codec(.raw, codecRaw: 0x0072_6177))
        guard case let .packet(_, payload) = events[1] else {
            Issue.record("expected packet")
            return
        }
        #expect(payload.count == 4)
    }

    @Test func disabledSentinelEmitsCodecAndSwallowsRest() {
        // codec id 0 = device disabled audio; trailing bytes must be ignored.
        var decoder = ScrcpyAudioStreamDecoder()
        let events = decoder.consume(Data([0x00, 0x00, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef]))
        #expect(events == [.codec(nil, codecRaw: 0)])
    }

    @Test func configErrorSentinelEmitsCodecOnly() {
        var decoder = ScrcpyAudioStreamDecoder()
        let events = decoder.consume(Data([0x00, 0x00, 0x00, 0x01]))
        #expect(events == [.codec(nil, codecRaw: 1)])
    }

    @Test func waitsForFullPayloadBeforeEmitting() {
        var decoder = ScrcpyAudioStreamDecoder()
        // codec(4) + header(12) but only 2 of 4 payload bytes.
        let head = decoder.consume(Data(Self.rawFixture[0 ..< 18]))
        #expect(head.count == 1)  // just the codec event
        let rest = decoder.consume(Data(Self.rawFixture[18 ..< 20]))
        #expect(rest.count == 1)
        guard case let .packet(_, payload) = rest[0] else {
            Issue.record("expected packet once payload completes")
            return
        }
        #expect(payload.count == 4)
    }

    @Test func haltsOnOversizedPacketSize() {
        // "raw" codec + a packet header whose size is an absurd 0xFFFFFFFF.
        var bytes: [UInt8] = [0x00, 0x72, 0x61, 0x77]
        bytes += [0, 0, 0, 0, 0, 0, 0, 0]    // ptsFlags
        bytes += [0xFF, 0xFF, 0xFF, 0xFF]    // absurd size
        bytes += [0x01, 0x02, 0x03]
        var decoder = ScrcpyAudioStreamDecoder()
        let events = decoder.consume(Data(bytes))
        #expect(!events.contains { if case .packet = $0 { true } else { false } })
        #expect(decoder.consume(Data([UInt8](repeating: 0xAB, count: 4096))).isEmpty)
    }
}
