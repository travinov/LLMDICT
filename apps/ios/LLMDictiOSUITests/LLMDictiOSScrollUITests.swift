import XCTest

@MainActor
final class LLMDictiOSScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordScreenScrollRevealsBottomContent() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons["Настройки"]
        let recordTab = app.tabBars.buttons["Запись"]
        let historyTab = app.tabBars.buttons["История"]
        XCTAssertTrue(recordTab.exists)
        XCTAssertTrue(historyTab.exists)
        XCTAssertTrue(settingsTab.exists)
        XCTAssertFalse(app.tabBars.buttons["Live"].exists)
        XCTAssertFalse(app.tabBars.buttons["FAQ"].exists)

        let bottomContent = app.staticTexts["Распознавание и оформление"]
        XCTAssertFalse(bottomContent.isHittable)

        app.swipeUp()

        XCTAssertTrue(bottomContent.waitForExistence(timeout: 5))
        XCTAssertTrue(bottomContent.isHittable)
    }

    func testFaqIsReachedFromSettingsAndShowsInstructions() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Настройки"].tap()
        let faqCell = app.cells.containing(.staticText, identifier: "FAQ и инструкции").firstMatch
        XCTAssertTrue(faqCell.waitForExistence(timeout: 5))
        faqCell.tap()

        XCTAssertTrue(app.staticTexts["FAQ и быстрый старт"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Быстрый старт"].exists)
        XCTAssertTrue(app.staticTexts["FAQ"].exists)
    }
}
