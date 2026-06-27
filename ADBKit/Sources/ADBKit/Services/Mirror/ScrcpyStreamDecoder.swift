import Foundation

/// scrcpy stream codec ids — 4-byte big-endian ASCII markers sent at the start
/// of each media socket (`demuxer.c` `SC_CODEC_ID_*`).
public enum ScrcpyCodecID: UInt32, Sendable, CaseIterable {
    case h264 = 0x6832_3634  // "h264"
    case h265 = 0x6832_3635  // "h265"
    case av1 = 0x0061_7631   // "av1"
    case opus = 0x6f70_7573  // "opus"
    case aac = 0x0061_6163   // "aac"
    case raw = 0x0072_6177   // "raw"
}

/// One scrcpy media packet's 12-byte header (`SC_PACKET_HEADER_SIZE`).
public struct ScrcpyPacketHeader: Sendable, Equatable {
    public static let byteCount = 12
    /// `SC_PACKET_FLAG_CONFIG` (bit 62): codec config (e.g. SPS/PPS); `pts` unset.
    public var isConfig: Bool
    /// `SC_PACKET_FLAG_KEY_FRAME` (bit 61).
    public var isKeyFrame: Bool
    /// Presentation timestamp in microseconds (low 61 bits); 0 for config packets.
    public var pts: UInt64
    public var payloadSize: Int

    private static let configFlag: UInt64 = 1 << 62
    private static let keyFrameFlag: UInt64 = 1 << 61
    private static let ptsMask: UInt64 = (1 << 61) - 1

    /// Decode the 8-byte PTS/flags word and 4-byte size that every media socket
    /// (video and audio alike) prefixes each packet with — the protocol's one
    /// error-prone bit of bit math, kept in a single place.
    public init(ptsFlags: UInt64, payloadSize: Int) {
        self.isConfig = (ptsFlags & Self.configFlag) != 0
        self.isKeyFrame = (ptsFlags & Self.keyFrameFlag) != 0
        self.pts = ptsFlags & Self.ptsMask
        self.payloadSize = payloadSize
    }

    public init(isConfig: Bool, isKeyFrame: Bool, pts: UInt64, payloadSize: Int) {
        self.isConfig = isConfig
        self.isKeyFrame = isKeyFrame
        self.pts = pts
        self.payloadSize = payloadSize
    }
}

/// Incremental, I/O-free decoder for a scrcpy video socket. Feed it raw bytes as
/// they arrive via `consume(_:)`; it emits high-level events as soon as a
/// complete unit is buffered, tolerating reads that split any field across
/// chunks. Pure value logic so the wire protocol is unit-testable with captured
/// fixtures — the transport owns the actual socket.
///
/// Stream layout (scrcpy 4.0, video socket, confirmed live):
/// `[dummy 0x00 (forward only)] [device name 64B] [codec id 4B]`
/// `[session meta: flags 4B | width 4B | height 4B]` then repeating
/// `[packet header 12B] [payload]`.
public struct ScrcpyStreamDecoder: Sendable {
    public enum Event: Sendable, Equatable {
        case deviceName(String)
        case videoHeader(codec: ScrcpyCodecID?, codecRaw: UInt32, width: Int, height: Int, clientResize: Bool)
        case packet(ScrcpyPacketHeader, payload: Data)
    }

    private enum Phase: Sendable {
        case dummyByte
        case deviceName
        case codecID
        case sessionMeta
        case packetHeader
        case packetPayload(ScrcpyPacketHeader)
        /// Unrecoverable desync (an absurd packet size): swallow trailing bytes.
        case halted
    }

    private let sendsDeviceName: Bool
    private var phase: Phase
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var pendingCodecRaw: UInt32 = 0

    /// Sanity ceiling for a packet's declared payload size. A single encoded
    /// frame is at most a few MB even at high resolution/bitrate; a larger value
    /// is a corrupt/desynced length, so the decoder halts rather than buffer
    /// toward the ~4 GB a UInt32 could claim.
    private static let maxPayloadSize = 64 * 1024 * 1024

    /// - Parameters:
    ///   - tunnelForward: in forward mode the server writes one leading dummy
    ///     byte before the stream so the client can confirm a real connection.
    ///   - sendsDeviceName: the server prefixes a 64-byte device-name field
    ///     (on by default).
    public init(tunnelForward: Bool = true, sendsDeviceName: Bool = true) {
        self.sendsDeviceName = sendsDeviceName
        if tunnelForward {
            phase = .dummyByte
        } else {
            phase = sendsDeviceName ? .deviceName : .codecID
        }
    }

    private var available: Int { buffer.count - cursor }

    public mutating func consume(_ incoming: Data) -> [Event] {
        if !incoming.isEmpty { buffer.append(contentsOf: incoming) }
        var events: [Event] = []
        parse: while true {
            switch phase {
            case .dummyByte:
                guard available >= 1 else { break parse }
                cursor += 1
                phase = sendsDeviceName ? .deviceName : .codecID
            case .deviceName:
                guard available >= 64 else { break parse }
                let raw = buffer[cursor ..< cursor + 64]
                cursor += 64
                events.append(.deviceName(Self.decodeName(raw)))
                phase = .codecID
            case .codecID:
                guard available >= 4 else { break parse }
                pendingCodecRaw = readU32BE()
                phase = .sessionMeta
            case .sessionMeta:
                guard available >= 12 else { break parse }
                let flags = readU32BE()
                let width = Int(readU32BE())
                let height = Int(readU32BE())
                events.append(.videoHeader(
                    codec: ScrcpyCodecID(rawValue: pendingCodecRaw),
                    codecRaw: pendingCodecRaw,
                    width: width,
                    height: height,
                    clientResize: (flags & 1) != 0))
                phase = .packetHeader
            case .packetHeader:
                guard available >= ScrcpyPacketHeader.byteCount else { break parse }
                let ptsFlags = readU64BE()
                let size = Int(readU32BE())
                // A corrupt/desynced length would otherwise buffer toward a
                // payload that never coheres; a binary stream can't resync, so halt.
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

    /// Drop the consumed prefix so the buffer doesn't grow without bound. Done
    /// once per `consume` rather than per field to keep it O(remaining).
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

    private static func decodeName(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }
}
