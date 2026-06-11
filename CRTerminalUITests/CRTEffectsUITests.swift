import XCTest

/// Phase 4/5 smoke tests: presets and degauss still work, the gallery now
/// lives in Settings, and the Phase 5 surfaces — tabs, splits, the search
/// bar, prompt jumping — don't take the app down.
final class CRTEffectsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGalleryDegaussAndPresetSwitching() throws {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows["CRTerminal"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Titlebar degauss button fires without incident.
        let degaussButton = window.buttons["Degauss"]
        XCTAssertTrue(degaussButton.exists, "titlebar degauss button missing")
        degaussButton.click()

        // The preset gallery lives in Settings now.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Preset Gallery…"].click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tabs["Presets"].click()
        func card(_ name: String) -> XCUIElement {
            settings.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        }
        for name in ["IBM 5151", "DEC VT220", "Amdek 310A", "Commodore 1702", "Museum off"] {
            XCTAssertTrue(card(name).exists, "\(name) missing from gallery")
        }
        card("IBM 5151").click()
        settings.buttons[XCUIIdentifierCloseWindow].click()

        // Switching from the View menu (radio items) keeps the app alive,
        // including the bezel preset which resizes the cell grid.
        for name in ["Commodore 1702", "Museum off", "DEC VT220"] {
            app.menuBars.menuBarItems["View"].click()
            app.menuBars.menuItems[name].click()
        }
        XCTAssertTrue(window.exists)
        app.typeText("echo ui-test-ok\n")
    }

    @MainActor
    func testTabsSplitsAndSearch() throws {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows["CRTerminal"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Split right, split down, type into the new pane, close it.
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuItems["Split Right"].click()
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuItems["Split Down"].click()
        app.typeText("echo split-ok\n")
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuItems["Close Pane"].click()
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuItems["Close Pane"].click()

        // New tab via the Shell menu, then close it.
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuItems["New Tab"].click()
        app.typeText("echo tab-ok\n")
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuItems["Close Pane"].click()

        // Search bar: type something findable, search for it, dismiss.
        app.typeText("echo find-me-marker\n")
        sleep(1)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuBars.menuItems["Find…"].click()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("find-me-marker\r")
        field.typeKey(.escape, modifierFlags: [])

        // Prompt jump menu items exist and fire harmlessly.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Jump to Previous Prompt"].click()
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Jump to Next Prompt"].click()

        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
