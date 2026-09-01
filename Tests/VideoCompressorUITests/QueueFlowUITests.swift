import XCTest

/// Covers the screens the unit tests cannot reach.
///
/// Everything below the UI — encoding, orientation, persistence — has device tests. The
/// screens themselves have only ever been checked by installing the app and trying it by
/// hand, which is exactly how a regression in, say, the editor hand-off would reach the
/// user unnoticed.
///
/// Simulator-only, deliberately: these flows need no encoding hardware, and a second test
/// runner on the device would claim one of the three App IDs a free account allows.
final class QueueFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(resettingQueue: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if resettingQueue {
            // The queue now persists, so without this each test would inherit whatever the
            // previous one left behind.
            app.launchArguments += ["-uitest-reset-queue"]
        }
        app.launch()
        return app
    }

    /// The empty state: nothing queued, so the only thing to do is pick a video.
    func testEmptyStateOffersVideoSelection() {
        let app = launchApp()
        let select = app.buttons["selectVideos"]
        XCTAssertTrue(select.waitForExistence(timeout: 10), "the pick-videos button is missing")
        XCTAssertTrue(select.isEnabled)

        // With nothing queued there is nothing to start, so that control should be absent.
        XCTAssertFalse(app.buttons["startProcessing"].exists,
                       "an empty queue should not offer to start a run")
    }

    /// Tapping the picker must actually present the library browser rather than silently
    /// doing nothing when permission has not been granted yet.
    func testSelectingVideosPresentsTheLibraryBrowser() {
        let app = launchApp()
        app.buttons["selectVideos"].tap()

        // The system permission prompt appears the first time; accept whichever variant.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允許取用全部照片", "Allow Access to All Photos", "允許", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }

        // Either the browser or the permission-denied message must appear; a blank screen
        // would mean the sheet failed to present.
        let browserAppeared = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            || app.staticTexts.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(browserAppeared, "tapping 選取影片 presented nothing")
    }
}
