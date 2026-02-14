import XCTest

final class rssssUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["RSSSS_UI_TESTING"] = "1"
        app.launchEnvironment["RSSSS_UI_TESTING_SEED_DATA"] = "1"
        app.launch()
    }

    func testLaunchShowsSeededFeedInSidebar() {
        XCTAssertTrue(app.buttons["UI Test Feed"].waitForExistence(timeout: 5))
    }

    func testAddFeedSheetShowsValidationForInvalidURL() {
        let addFeedButton = app.buttons["Add feed"]
        XCTAssertTrue(addFeedButton.waitForExistence(timeout: 5))
        addFeedButton.tap()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        let textField = sheet.textFields["https://example.com/feed.xml"]
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        textField.tap()
        textField.typeText("http://example.com/insecure.xml")

        sheet.buttons["Add"].tap()
        XCTAssertTrue(sheet.staticTexts["Enter a valid HTTPS URL (for example: https://example.com/feed.xml)."].waitForExistence(timeout: 2))
    }

    func testAddOPMLSheetShowsValidationForInvalidURL() {
        let addOPMLButton = app.buttons["Add OPML"]
        XCTAssertTrue(addOPMLButton.waitForExistence(timeout: 5))
        addOPMLButton.tap()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        let textField = sheet.textFields["https://example.com/feeds.opml"]
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        textField.tap()
        textField.typeText("http://example.com/feeds.opml")

        sheet.buttons["Import"].tap()
        XCTAssertTrue(sheet.staticTexts["Enter a valid HTTPS URL (for example: https://example.com/feeds.opml)."].waitForExistence(timeout: 2))
    }
}
