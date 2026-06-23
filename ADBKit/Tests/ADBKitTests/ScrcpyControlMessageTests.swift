import Foundation
import Testing
@testable import ADBKit

@Suite struct ScrcpyControlMessageTests {
    @Test func keycodeSerializesTo14Bytes() {
        // BACK keycode (4), down, no repeat, no modifiers.
        let bytes = [UInt8](ScrcpyControlMessage
            .injectKeycode(action: .down, keycode: 4, repeatCount: 0, metaState: 0)
            .serialized())
        #expect(bytes == [0x00, 0x00, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func textSerializesWithBigEndianLengthPrefix() {
        let bytes = [UInt8](ScrcpyControlMessage.injectText("hi").serialized())
        #expect(bytes == [0x01, 0, 0, 0, 2, 0x68, 0x69])  // type, len=2, "hi"
    }

    @Test func touchSerializesTo32BytesWithFullPressure() {
        let bytes = [UInt8](ScrcpyControlMessage.injectTouch(
            action: .down, pointerID: 0, x: 100, y: 200,
            screenWidth: 800, screenHeight: 500,
            pressure: 1.0, actionButton: 0, buttons: 0).serialized())
        #expect(bytes.count == 32)
        #expect(bytes[0] == 0x02)            // type
        #expect(bytes[1] == 0x00)            // action = down
        #expect(Array(bytes[2 ..< 10]) == [0, 0, 0, 0, 0, 0, 0, 0])  // pointerId
        #expect(Array(bytes[10 ..< 14]) == [0, 0, 0, 100])           // x = 100
        #expect(Array(bytes[14 ..< 18]) == [0, 0, 0, 200])           // y = 200
        #expect(Array(bytes[18 ..< 20]) == [0x03, 0x20])             // width = 800
        #expect(Array(bytes[20 ..< 22]) == [0x01, 0xF4])             // height = 500
        #expect(Array(bytes[22 ..< 24]) == [0xFF, 0xFF])             // pressure 1.0 -> 0xffff
    }

    @Test func backOrScreenOnSerializesTo2Bytes() {
        #expect([UInt8](ScrcpyControlMessage.backOrScreenOn(action: .down).serialized()) == [0x04, 0x00])
    }

    @Test func scrollSerializesTo21Bytes() {
        let bytes = [UInt8](ScrcpyControlMessage.injectScroll(
            x: 10, y: 20, screenWidth: 800, screenHeight: 500,
            hscroll: 0, vscroll: 1.0, buttons: 0).serialized())
        #expect(bytes.count == 21)
        #expect(bytes[0] == 0x03)
        #expect(Array(bytes[13 ..< 15]) == [0x00, 0x00])  // hscroll 0
        #expect(Array(bytes[15 ..< 17]) == [0x7F, 0xFF])  // vscroll 1.0 -> 0x7fff
    }

    @Test func fixedPointConversions() {
        #expect(ScrcpyControlMessage.floatToU16FixedPoint(1.0) == 0xffff)
        #expect(ScrcpyControlMessage.floatToU16FixedPoint(0.0) == 0)
        #expect(ScrcpyControlMessage.floatToU16FixedPoint(0.5) == 0x8000)
        #expect(ScrcpyControlMessage.floatToI16FixedPoint(1.0) == 0x7fff)
        #expect(ScrcpyControlMessage.floatToI16FixedPoint(-1.0) == -0x8000)
        #expect(ScrcpyControlMessage.floatToI16FixedPoint(0.0) == 0)
    }
}
