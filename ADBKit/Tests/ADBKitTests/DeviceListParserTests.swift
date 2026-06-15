import Testing
@testable import ADBKit

@Suite struct DeviceListParserTests {
    @Test func parsesUsbDeviceWithTags() {
        let output = """
        List of devices attached
        3A091FDJG0005F         device usb:34603008X product:panther model:Pixel_7 device:panther transport_id:1
        """
        let devices = DeviceListParser.parse(output)
        #expect(devices.count == 1)
        let device = try! #require(devices.first)
        #expect(device.serial == "3A091FDJG0005F")
        #expect(device.state == "device")
        #expect(device.model == "Pixel 7")
        #expect(device.product == "panther")
        #expect(device.transportId == "1")
        #expect(device.label == "Pixel 7 (005F)")
        #expect(!device.isWireless)
        #expect(device.isReady)
    }

    @Test func parsesWirelessDevice() {
        let devices = DeviceListParser.parse("192.168.1.42:5555   device model:Pixel_7 transport_id:3")
        #expect(devices.count == 1)
        #expect(devices[0].isWireless)
        #expect(devices[0].serial == "192.168.1.42:5555")
    }

    @Test func parsesCrlfOutputWithoutStrandedCarriageReturns() {
        // `\r\n` is a single grapheme, so splitting on "\n" leaves the whole
        // dump as one line. The reader must split on any newline so a CRLF
        // device is still recognized as wireless and ready.
        let output = "List of devices attached\r\n192.168.1.42:5555   device model:Pixel_7\r\n"
        let devices = DeviceListParser.parse(output)
        #expect(devices.count == 1)
        let device = try! #require(devices.first)
        #expect(device.serial == "192.168.1.42:5555")
        #expect(device.state == "device")
        #expect(device.isWireless)
        #expect(device.isReady)
    }

    @Test func parsesUnauthorizedAndOffline() {
        let output = """
        List of devices attached
        emulator-5554   unauthorized
        ZX1G22LM7B      offline
        """
        let devices = DeviceListParser.parse(output)
        #expect(devices.count == 2)
        #expect(devices[0].state == "unauthorized")
        #expect(!devices[0].isReady)
        #expect(devices[1].state == "offline")
    }

    @Test func skipsDaemonNoiseLines() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        adb server version (41) doesn't match this client (42); killing...
        List of devices attached
        SERIAL1   device
        """
        let devices = DeviceListParser.parse(output)
        #expect(devices.count == 1)
        #expect(devices[0].serial == "SERIAL1")
    }

    @Test func emptyOutputYieldsNoDevices() {
        #expect(DeviceListParser.parse("List of devices attached\n\n").isEmpty)
        #expect(DeviceListParser.parse("").isEmpty)
    }

    @Test func deviceWithoutModelUsesSerialAsLabel() {
        let devices = DeviceListParser.parse("SOMESERIAL  device")
        #expect(devices[0].label == "SOMESERIAL")
    }

    @Test func shortSerialKeepsLastFourAlphanumerics() {
        #expect(DeviceListParser.shortSerial("192.168.1.42:5555") == "5555")
        #expect(DeviceListParser.shortSerial("ab") == "ab")
    }
}
