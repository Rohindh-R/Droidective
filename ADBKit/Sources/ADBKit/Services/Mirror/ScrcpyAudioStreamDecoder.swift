import Foundation

/// Incremental, I/O-free decoder for a scrcpy *audio* socket.
///
/// Unlike the video socket it carries no forward-mode dummy byte, no 64-byte
/// device name, and no width/height session meta (those are video-only and ride
/// the first socket). The audio socket is just a 4-byte codec id followed by
/// repeating `[packet header 12B] [payload]` (`demuxer.c`, audio path).
///
/// Codec id `0` means the device disabled audio (e.g. Android < 11, or output
/// capture unavailable) and `1` means a device-side configuration error. Both
/// surface as `.codec(nil, …)` with no packets after, so the caller falls back
/// to a silent, video-only mirror. Pure value logic so the wire format is
/// unit-testable; the transport owns the socket.
public struct ScrcpyAudioStreamDecoder: Sendable {
    public enum Event: Sendable, Equatable {
        /// The leading codec id. `codec` is nil for the `0`/`1` sentinels and any
        /// id we don't model; inspect `codecRaw` to tell them apart.
        case codec(ScrcpyCodecID?, codecRaw: UInt32)
        case packet(ScrcpyPacketHeader, payload: Data)
    }

    private enum Phase: Sendable {
        case codecID
        case packetHeader
        case packetPayload(ScrcpyPacketHeader)
        /// Codec disabled/errored: no stream follows, so swallow any trailing bytes.
        case halted
    }

    private var phase: Phase = .codecID
    private var buffer: [UInt8] = []
    private var cursor = 0

    /// Sanity ceiling for a packet's declared payload size; past this is a
    /// corrupt/desynced length, so halt rather than buffer toward ~4 GB.
    private static let maxPayloadSize = 64 * 1024 * 1024

    public init() {}

    private var available: Int { buffer.count - cursor }

    public mutating func consume(_ incoming: Data) -> [Event] {
        if !incoming.isEmpty { buffer.append(contentsOf: incoming) }
        var events: [Event] = []
        parse: while true {
            switch phase {
            case .codecID:
                guard available >= 4 else { break parse }
                let raw = readU32BE()
                events.append(.codec(ScrcpyCodecID(rawValue: raw), codecRaw: raw))
                // 0 = disabled, 1 = config error: nothing more arrives.
                phase = (raw == 0 || raw == 1) ? .halted : .packetHeader
            case .packetHeader:
                guard available >= ScrcpyPacketHeader.byteCount else { break parse }
                let ptsFlags = readU64BE()
                let size = Int(readU32BE())
                guard size <= Self.maxPayloadSize else { phase = .halted; break }
                phase = .packetPayload(ScrcpyPacketHeader(ptsFlags: ptsFlags, payloadSize: size))
            case let .packetPayload(header):
                guard available >= header.payloadSize else { break parse }
                let payload = Data(buffer[cursor ..< cursor + header.payloadSize])
                cursor += header.payloadSize
                events.append(.packet(header, payload: payload))
                phase = .packetHeader
            case .halted:
                cursor = buffer.count
                break parse
            }
        }
        compact()
        return events
    }

    private mutating func compact() {
        guard cursor > 0 else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }

    private mutating func readU32BE() -> UInt32 {
        var value: UInt32 = 0
        for index in 0 ..< 4 { value = (value << 8) | UInt32(buffer[cursor + index]) }
        cursor += 4
        return value
    }

    private mutating func readU64BE() -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 8 { value = (value << 8) | UInt64(buffer[cursor + index]) }
        cursor += 8
        return value
    }
}
