import Foundation

/// Decides whether a mirror session that just ended should be reconnected
/// without audio.
///
/// scrcpy starts its audio encoder while bringing the session up. On devices
/// that can't capture audio — most emulators, where `AudioRecord` can't be
/// created — that encoder fails *before* the first video frame and scrcpy aborts
/// the whole session, video included. So when audio was requested and the
/// session died before ever streaming a frame, audio is the likely culprit and a
/// video-only reconnect keeps mirroring working. If video had already streamed,
/// the session ended for some other reason and must not be silently restarted.
public enum MirrorAudioFallback {
    public static func shouldRetryWithoutAudio(audioRequested: Bool, everStreamed: Bool) -> Bool {
        audioRequested && !everStreamed
    }
}
