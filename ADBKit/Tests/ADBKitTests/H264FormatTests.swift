import CoreMedia
import Foundation
import Testing
@testable import ADBKit

@Suite struct H264FormatTests {
    /// Build a format description from the captured config packet's SPS/PPS and
    /// confirm VideoToolbox parses the dimensions the SPS encodes — which must
    /// match the session-meta width/height (800x500) the server also sent.
    @Test func formatDescriptionDimensionsMatchSessionMeta() {
        let bytes = ScrcpyStreamDecoderTests.hexBytes(ScrcpyStreamDecoderTests.fixtureHex)
        var decoder = ScrcpyStreamDecoder(tunnelForward: true)
        let events = decoder.consume(Data(bytes))

        let config = events.compactMap { event -> Data? in
            if case let .packet(header, payload) = event, header.isConfig { return payload }
            return nil
        }.first
        guard let config,
              let sets = H264NAL.parameterSets(fromAnnexB: config),
              let format = H264Format.formatDescription(sps: sets.sps, pps: sets.pps)
        else {
            Issue.record("could not build a format description from the config packet")
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 800)
        #expect(dimensions.height == 500)
    }

    @Test func sampleBufferWrapsAvccFrame() {
        let bytes = ScrcpyStreamDecoderTests.hexBytes(ScrcpyStreamDecoderTests.fixtureHex)
        var decoder = ScrcpyStreamDecoder(tunnelForward: true)
        let events = decoder.consume(Data(bytes))
        let config = events.compactMap { event -> Data? in
            if case let .packet(header, payload) = event, header.isConfig { return payload }
            return nil
        }.first
        guard let config,
              let sets = H264NAL.parameterSets(fromAnnexB: config),
              let format = H264Format.formatDescription(sps: sets.sps, pps: sets.pps)
        else {
            Issue.record("missing format description")
            return
        }
        // Wrap an arbitrary AVCC payload (reuse the config bytes) and confirm a
        // ready sample buffer with our format description comes back.
        let avcc = H264NAL.avcc(fromAnnexB: config)
        let sample = H264Format.sampleBuffer(
            avcc: avcc, formatDescription: format, pts: CMTime(value: 0, timescale: 1_000_000))
        #expect(sample != nil)
        #expect(sample.map { CMSampleBufferIsValid($0) } == true)
    }
}
