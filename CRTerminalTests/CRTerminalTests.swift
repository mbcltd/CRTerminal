import AppKit
import Foundation
import Testing
import TerminalCore
@testable import CRTerminal

struct URLDetectionTests {
    private func row(_ text: String) -> [Cell] {
        text.unicodeScalars.map { Cell(glyph: $0.value) }
    }

    @Test func detectsHTTPSURLs() {
        let line = row("see https://example.com/a?b=1 for details")
        let url = URLDetection.detect(in: line, atColumn: 10)
        #expect(url?.absoluteString == "https://example.com/a?b=1")
        // Clicking outside the URL finds nothing.
        #expect(URLDetection.detect(in: line, atColumn: 1) == nil)
    }

    @Test func stripsTrailingPunctuation() {
        let line = row("read https://example.com/doc.")
        let url = URLDetection.detect(in: line, atColumn: 12)
        #expect(url?.absoluteString == "https://example.com/doc")
    }

    @Test func detectsExistingPaths() {
        let line = row("config at /tmp lives here")
        let url = URLDetection.detect(in: line, atColumn: 11)
        #expect(url?.path == "/tmp")
        let missing = row("ghost /no/such/path/xyz here")
        #expect(URLDetection.detect(in: missing, atColumn: 8) == nil)
    }

    @Test func osc8TargetParses() {
        #expect(URLDetection.url(from: "https://example.com") != nil)
        #expect(URLDetection.url(from: "not a url") == nil)
    }
}

struct TerminalSettingsTests {
    @Test func settingsRoundTripThroughJSON() throws {
        var settings = TerminalSettings()
        settings.fontSize = 15
        settings.presetName = "IBM 5151"
        settings.workingDirectory = "~/dev"
        settings.scrollbackLines = 5000
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func workingDirectoryDefaultsToHomeAndExpandsTilde() {
        var settings = TerminalSettings()
        #expect(settings.resolvedWorkingDirectory == NSHomeDirectory())
        settings.workingDirectory = "~"
        #expect(settings.resolvedWorkingDirectory == NSHomeDirectory())
        settings.workingDirectory = "/tmp"
        #expect(settings.resolvedWorkingDirectory == "/tmp")
        // A vanished path must not stop shells from spawning.
        settings.workingDirectory = "/no/such/place"
        #expect(settings.resolvedWorkingDirectory == NSHomeDirectory())
    }

    @Test func fontIsFixedPitchAndSizeClamps() {
        var settings = TerminalSettings()
        #expect(settings.font.isFixedPitch)
        settings.fontSize = 500 // clamped
        #expect(settings.font.pointSize <= 72)
    }

    @Test func restorationDefaultsToAlwaysAndRoundTrips() throws {
        var settings = TerminalSettings()
        #expect(settings.restoration == .always)
        settings.restoration = .system
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: data)
        #expect(decoded.restoration == .system)
    }

    @Test func restorationMissingFromOldBlobDecodesAsAlways() throws {
        // A settings JSON written before the field existed must still load,
        // taking the current default (Always).
        let json = #"{"fontSize":13,"presetName":"Dark","scrollbackLines":10000,"ligatures":true}"#
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self, from: Data(json.utf8))
        #expect(decoded.restoration == .always)
    }

    @Test @MainActor func storeTogglesRestorationEnabled() {
        let defaults = UserDefaults(suiteName: "restoration-test-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.restorationEnabled) // default (Always) is enabled
        store.setRestoration(.never)
        #expect(!store.restorationEnabled)
        store.setRestoration(.always)
        #expect(store.restorationEnabled)
        // The in-memory override doesn't persist.
        store.overrideRestoration(.never)
        #expect(!store.restorationEnabled)
        #expect(SettingsStore(defaults: defaults).settings.restoration == .always)
    }
}
