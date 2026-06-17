import Testing
@testable import CRTerminal

/// Session restoration: the launch-time restore decision. Restore is driven
/// from our own on-disk layout (not AppKit window restoration), so this pure
/// decision is what actually gates it — `System` must follow the macOS "keep
/// windows when quitting" preference, which is the bug that made the default
/// mode feel unreliable.
struct RestoreDecisionTests {
    @Test func neverNeverRestores() {
        #expect(!AppDelegate.shouldRestore(mode: .never, systemKeepsWindows: true))
        #expect(!AppDelegate.shouldRestore(mode: .never, systemKeepsWindows: false))
    }

    @Test func alwaysAlwaysRestores() {
        #expect(AppDelegate.shouldRestore(mode: .always, systemKeepsWindows: true))
        #expect(AppDelegate.shouldRestore(mode: .always, systemKeepsWindows: false))
    }

    @Test func systemFollowsThePreference() {
        #expect(AppDelegate.shouldRestore(mode: .system, systemKeepsWindows: true))
        #expect(!AppDelegate.shouldRestore(mode: .system, systemKeepsWindows: false))
    }
}
