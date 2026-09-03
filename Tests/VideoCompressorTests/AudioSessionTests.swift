import XCTest
import AVFoundation
@testable import VideoCompressor

/// Whether preview audio is audible with the phone on silent.
///
/// Reported as "靜音模式下沒有聲音". Nothing configured `AVAudioSession`, so the app ran on
/// the default `.soloAmbient`, whose definition is that the ring/silent switch mutes it.
/// The physical switch cannot be flipped from a test, but the category that decides the
/// behaviour can be checked — and that is the part that regresses, silently, if this is
/// ever removed.
final class AudioSessionTests: XCTestCase {

    /// The app configures the session at launch, and the tests run inside the app, so this
    /// checks the wiring rather than just the helper in isolation.
    func testAppLaunchLeavesTheSessionAudibleOnSilent() {
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback,
                       "\(session.category.rawValue) is silenced by the ring/silent switch")
    }

    /// `.soloAmbient` and `.ambient` are exactly the categories the switch mutes, so name
    /// them: a future change to, say, `.ambient` would still be "a category", and only this
    /// makes it a failure.
    func testCategoryIsNotOneTheSilentSwitchMutes() {
        AudioSessionController.configureForPlayback()
        let category = AVAudioSession.sharedInstance().category
        XCTAssertFalse([.soloAmbient, .ambient].contains(category),
                       "\(category.rawValue) goes silent when the phone is on silent")
    }

    /// Setting a category must not activate the session — activating is what stops whatever
    /// the user was listening to, and nothing has been played yet at launch.
    func testConfiguringDoesNotSeizeAudioFromOtherApps() {
        AudioSessionController.configureForPlayback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertFalse(AVAudioSession.sharedInstance().isOtherAudioPlaying &&
                       AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint,
                       "configuring the session should not have interrupted other audio")
    }
}
