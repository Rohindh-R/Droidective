import Foundation

/// A message the device sends back over the control socket (`device_msg.c`).
public enum ScrcpyDeviceMessage: Sendable, Equatable {
    case clipboard(String)
    case ackClipboard(sequence: UInt64)
}

/// Incremental, I/O-free parser for the device→client control stream. Feed it the
/// control socket's incoming bytes; it emits messages as they complete, tolerating
/// split reads. UHID-output messages are consumed but not surfaced.
public struct ScrcpyDeviceMessageDecoder: Sendable {
    private enum MessageType: UInt8 {
        case clipboard = 0
        case ackClipboard = 1
        case uhidOutput = 2
    }

    private var buffer: [UInt8] = []
    private var cursor = 0

    public init() {}

    private var available: Int { buffer.count - cursor }

    public mutating func consume(_ incoming: Data) -> [ScrcpyDeviceMessage] {
        if !incoming.isEmpty { buffer.append(contentsOf: incoming) }
        var messages: [ScrcpyDeviceMessage] = []
        parse: while available >= 1 {
            guard let type = MessageType(rawValue: buffer[cursor]) else {
                // Unknown type — can't resync safely; drop the rest.
                buffer.removeAll()
                cursor = 0
                break
            }
            switch type {
            case .clipboard:
                guard available >= 5 else { break parse }
                let length = Int(readU32BE(at: cursor + 1))
                guard available >= 5 + length else { break parse }
                let text = String(decoding: buffer[(cursor + 5) ..< (cursor + 5 + length)], as: UTF8.self)
                cursor += 5 + length
                messages.append(.clipboard(text))
            case .ackClipboard:
                guard available >= 9 else { break parse }
                messages.append(.ackClipboard(sequence: readU64BE(at: cursor + 1)))
                cursor += 9
            case .uhidOutput:
                guard available >= 5 else { break parse }
                let size = Int(readU16BE(at: cursor + 3))
                guard available >= 5 + size else { break parse }
                cursor += 5 + size
            }
        }
        compact()
        return messages
    }

    private mutating func compact() {
        guard cursor > 0 else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }

    private func readU16BE(at index: Int) -> UInt16 {
        (UInt16(buffer[index]) << 8) | UInt16(buffer[index + 1])
    }

    private func readU32BE(at index: Int) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0 ..< 4 { value = (value << 8) | UInt32(buffer[index + offset]) }
        return value
    }

    private func readU64BE(at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0 ..< 8 { value = (value << 8) | UInt64(buffer[index + offset]) }
        return value
    }
}
