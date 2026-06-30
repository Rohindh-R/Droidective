import Testing
@testable import ADBKit

@Suite struct MirrorAudioFallbackTests {
    @Test func retriesWhenAudioOnAndNeverStreamed() {
        #expect(MirrorAudioFallback.shouldRetryWithoutAudio(
            audioRequested: true, everStreamed: false))
    }

    @Test func noRetryOnceVideoStreamed() {
        #expect(!MirrorAudioFallback.shouldRetryWithoutAudio(
            audioRequested: true, everStreamed: true))
    }

    @Test func noRetryWhenAudioWasNotRequested() {
        // Already video-only: nothing to fall back to (and avoids a retry loop).
        #expect(!MirrorAudioFallback.shouldRetryWithoutAudio(
            audioRequested: false, everStreamed: false))
        #expect(!MirrorAudioFallback.shouldRetryWithoutAudio(
            audioRequested: false, everStreamed: true))
    }
}
