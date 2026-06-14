import AppKit

/// macOS state-restoration entry point (session restoration R3). Every
/// terminal window names this as its `restorationClass`; on relaunch AppKit
/// calls back here once per previously-open window identifier (between
/// `applicationWillFinishLaunching` and `applicationDidFinishLaunching`),
/// honouring the system "Close windows when quitting an app" preference. The
/// rebuild itself lives in the app delegate, which owns the window list.
final class WindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let delegate = AppDelegate.shared else {
                completionHandler(nil, nil)
                return
            }
            delegate.restoreWindow(
                identifier: identifier, state: state,
                completionHandler: completionHandler)
        }
    }
}
