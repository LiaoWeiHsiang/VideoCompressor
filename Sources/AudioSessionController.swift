import AVFoundation

/// Lets preview audio play while the phone is on silent.
///
/// Without any configuration an app gets `.soloAmbient`, whose whole definition is that the
/// ring/silent switch mutes it — so the editor was silent for anyone who keeps their phone
/// on silent, with nothing on screen to explain why. `.playback` is the category for audio
/// the user asked to hear, and it ignores the switch.
enum AudioSessionController {

    /// Set the category, but do not activate the session.
    ///
    /// Activating is what interrupts whatever else is playing, and `AVPlayer` does it by
    /// itself the moment something actually plays. Doing it here instead would stop the
    /// user's music at launch, before they had asked for a single frame.
    static func configureForPlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    /// Hand the session back so other apps' audio can resume.
    ///
    /// Music paused by our playback stays paused until the session is deactivated *with*
    /// `.notifyOthersOnDeactivation` — without the option, or without this call at all, the
    /// user has to go and press play again. Throws while our own player is still running,
    /// which is why the failure is ignored: there is nothing to hand back yet.
    static func relinquish() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
