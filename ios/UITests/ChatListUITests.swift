import XCTest

/// Read-only: opens and dismisses menus without choosing anything.
/// Runs against a signed-in simulator; pass a demo login through the
/// ASGARD_UITEST_LOGIN environment variable ("server user password") on a fresh install.
final class ChatListUITests: XCTestCase {
    @MainActor func testLongPressChatShowsMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-noPush"]
        if let login = ProcessInfo.processInfo.environment["ASGARD_UITEST_LOGIN"] {
            app.launchArguments += ["-signIn"] + login.split(separator: " ").map(String.init)
        }
        app.launch()
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no chats listed")
        // One press only: a second press can land on the first menu's items
        // (e.g. Archive) and change the account's data. Cell 0 is the folder bar.
        app.cells.element(boundBy: 1).press(forDuration: 1.2)
        let menu = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Pin", "Unpin"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "context menu didn't open")
        XCTAssertEqual(app.state, .runningForeground)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
