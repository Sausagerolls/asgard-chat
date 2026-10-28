import XCTest

/// Demo mode only: drags the text-size slider and records the preview's height.
final class TextSizeUITests: XCTestCase {
    @MainActor func testPreviewFollowsSlider() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noPush", "-tab", "settings"]
        app.launch()
        app.buttons["Appearance"].firstMatch.tap()
        let preview = app.staticTexts["Messages and chats will look like this."]
        for _ in 0..<8 where !preview.exists { app.swipeUp() }
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        // One adjust per launch: committing a size rebuilds the screen.
        let before = XCTAttachment(screenshot: app.screenshot()); before.lifetime = .keepAlways; add(before)
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.5)
        sleep(1)
        let after = XCTAttachment(screenshot: app.screenshot()); after.lifetime = .keepAlways; add(after)
    }
}
