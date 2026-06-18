import XCTest

extension XCUIApplication {
    /// Launch with a throwaway state store and no session restoration, so UI
    /// tests start from a blank slate and never load (or clobber) the user's
    /// real saved sessions — which would otherwise restore their working
    /// directories and trigger macOS folder-access prompts mid-test. See
    /// `AppDelegate.isCleanLaunch`.
    func launchClean() {
        launchEnvironment["CRT_CLEAN_LAUNCH"] = "1"
        launch()
    }
}
