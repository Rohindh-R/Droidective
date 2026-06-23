import Foundation
import Testing
@testable import ADBKit

@Suite struct ScrcpyDeviceMessageTests {
    @Test func parsesClipboardMessage() {
        // type 0, length 2, "hi"
        var decoder = ScrcpyDeviceMessageDecoder()
        let messages = decoder.consume(Data([0x00, 0, 0, 0, 2, 0x68, 0x69]))
        #expect(messages == [.clipboard("hi")])
    }

    @Test func parsesAckClipboardMessage() {
        var decoder = ScrcpyDeviceMessageDecoder()
        let messages = decoder.consume(Data([0x01, 0, 0, 0, 0, 0, 0, 0, 5]))
        #expect(messages == [.ackClipboard(sequence: 5)])
    }

    @Test func consumesUhidOutputWithoutEmitting() {
        // type 2 (uhid): id(2)+size(2)+data(2), then a clipboard — only the
        // clipboard is surfaced.
        var decoder = ScrcpyDeviceMessageDecoder()
        let messages = decoder.consume(Data([
            0x02, 0, 1, 0, 2, 0xAA, 0xBB,
            0x00, 0, 0, 0, 1, 0x41,
        ]))
        #expect(messages == [.clipboard("A")])
    }

    @Test func toleratesSplitAcrossChunks() {
        var decoder = ScrcpyDeviceMessageDecoder()
        var messages: [ScrcpyDeviceMessage] = []
        for byte in [UInt8]([0x00, 0, 0, 0, 3, 0x61, 0x62, 0x63]) {
            messages += decoder.consume(Data([byte]))
        }
        #expect(messages == [.clipboard("abc")])
    }
}
