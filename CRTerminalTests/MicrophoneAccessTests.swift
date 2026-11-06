import Foundation
import Testing
@testable import CRTerminal

/// crterm records nothing itself, but macOS attributes the microphone use of
/// anything running in a session (Claude Code's `/voice`) to crterm. Without a
/// usage string there is no prompt to allow, and those programs silently capture
/// silence. The matching audio-input entitlement only exists in signed builds,
/// so `Scripts/release.sh` checks that half; CI builds unsigned.
struct MicrophoneAccessTests {
    @Test func infoPlistExplainsMicrophoneUse() {
        let reason = Bundle.main.object(
            forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        #expect(reason?.isEmpty == false)
    }
}
