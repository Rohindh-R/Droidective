import Foundation

/// A scrcpy control-protocol message the client sends to the device. Only the
/// types the in-app mirror needs are modeled. `serialized()` produces the exact
/// big-endian wire bytes (confirmed against scrcpy 4.0 `control_msg.c`); kept
/// pure so the encoding is unit-tested.
public enum ScrcpyControlMessage: Sendable, Equatable {
    case injectKeycode(action: KeyAction, keycode: UInt32, repeatCount: UInt32, metaState: UInt32)
    case injectText(String)
    case injectTouch(
        action: TouchAction, pointerID: UInt64,
        x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16,
        pressure: Float, actionButton: UInt32, buttons: UInt32)
    case injectScroll(
        x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16,
        hscroll: Float, vscroll: Float, buttons: UInt32)
    case backOrScreenOn(action: KeyAction)
    /// Ask the device to copy/cut its current selection (it replies with its
    /// clipboard as a device message).
    case getClipboard(copyKey: CopyKey)
    /// Set the device clipboard; when `paste`, the device also pastes it.
    case setClipboard(sequence: UInt64, paste: Bool, text: String)

    /// Android `KeyEvent` action.
    public enum KeyAction: UInt8, Sendable { case down = 0, up = 1 }
    /// Android `MotionEvent` action.
    public enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2 }
    /// `sc_copy_key`.
    public enum CopyKey: UInt8, Sendable { case none = 0, copy = 1, cut = 2 }

    private enum MessageType: UInt8 {
        case injectKeycode = 0
        case injectText = 1
        case injectTouch = 2
        case injectScroll = 3
        case backOrScreenOn = 4
        case getClipboard = 8
        case setClipboard = 9
    }

    public func serialized() -> Data {
        var data = Data()
        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            data.append(MessageType.injectKeycode.rawValue)
            data.append(action.rawValue)
            data.appendBigEndian(keycode)
            data.appendBigEndian(repeatCount)
            data.appendBigEndian(metaState)

        case let .injectText(text):
            data.append(MessageType.injectText.rawValue)
            let bytes = Array(text.utf8)
            data.appendBigEndian(UInt32(bytes.count))
            data.append(contentsOf: bytes)

        case let .injectTouch(action, pointerID, x, y, width, height, pressure, actionButton, buttons):
            data.append(MessageType.injectTouch.rawValue)
            data.append(action.rawValue)
            data.appendBigEndian(pointerID)
            data.appendPosition(x: x, y: y, width: width, height: height)
            data.appendBigEndian(Self.floatToU16FixedPoint(pressure))
            data.appendBigEndian(actionButton)
            data.appendBigEndian(buttons)

        case let .injectScroll(x, y, width, height, hscroll, vscroll, buttons):
            data.append(MessageType.injectScroll.rawValue)
            data.appendPosition(x: x, y: y, width: width, height: height)
            data.appendBigEndian(UInt16(bitPattern: Self.floatToI16FixedPoint(hscroll)))
            data.appendBigEndian(UInt16(bitPattern: Self.floatToI16FixedPoint(vscroll)))
            data.appendBigEndian(buttons)

        case let .backOrScreenOn(action):
            data.append(MessageType.backOrScreenOn.rawValue)
            data.append(action.rawValue)

        case let .getClipboard(copyKey):
            data.append(MessageType.getClipboard.rawValue)
            data.append(copyKey.rawValue)

        case let .setClipboard(sequence, paste, text):
            data.append(MessageType.setClipboard.rawValue)
            data.appendBigEndian(sequence)
            data.append(paste ? 1 : 0)
            let bytes = Array(text.utf8)
            data.appendBigEndian(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    /// `sc_float_to_u16fp`: a normalized [0,1] float as 16-bit fixed point.
    static func floatToU16FixedPoint(_ value: Float) -> UInt16 {
        let clamped = max(0, min(1, value))
        let scaled = UInt32(clamped * 65_536)
        return scaled >= 0xffff ? 0xffff : UInt16(scaled)
    }

    /// `sc_float_to_i16fp`: a normalized [-1,1] float as signed 16-bit fixed point.
    static func floatToI16FixedPoint(_ value: Float) -> Int16 {
        let clamped = max(-1, min(1, value))
        let scaled = Int32(clamped * 32_768)
        if scaled >= 0x7fff { return 0x7fff }
        if scaled <= -0x8000 { return -0x8000 }
        return Int16(scaled)
    }
}

extension Data {
    fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// scrcpy `write_position`: x(i32), y(i32), width(u16), height(u16), big-endian.
    fileprivate mutating func appendPosition(x: Int32, y: Int32, width: UInt16, height: UInt16) {
        appendBigEndian(UInt32(bitPattern: x))
        appendBigEndian(UInt32(bitPattern: y))
        appendBigEndian(width)
        appendBigEndian(height)
    }
}
