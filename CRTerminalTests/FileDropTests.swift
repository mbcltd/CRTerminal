import Foundation
import Testing
@testable import CRTerminal

struct FileDropTests {
    // MARK: Escape + space separator + trailing space

    @Test func singleSimplePathPassesThroughWithTrailingSpace() {
        #expect(FileDrop.payload(for: ["/Users/dmb/notes.txt"])
            == "/Users/dmb/notes.txt ")
    }

    @Test func pathWithSpacesIsShellEscaped() {
        #expect(FileDrop.payload(for: ["/Users/dmb/My File.txt"])
            == "'/Users/dmb/My File.txt' ")
    }

    @Test func multiplePathsAreSpaceSeparatedAndEscaped() {
        let out = FileDrop.payload(for: ["/a/b.txt", "/c/d e.txt"])
        #expect(out == "/a/b.txt '/c/d e.txt' ")
    }

    @Test func shellMetacharactersAreQuoted() {
        // A path that would otherwise expand/execute at the prompt.
        let out = FileDrop.payload(for: ["/tmp/$(rm -rf ~).txt"])
        #expect(out == "'/tmp/$(rm -rf ~).txt' ")
    }

    @Test func embeddedSingleQuoteIsBrokenOut() {
        #expect(FileDrop.shellEscape("it's.txt") == "'it'\\''s.txt'")
    }

    // MARK: Safety — control characters can never reach the line

    @Test func controlCharacterInjectionIsStripped() {
        // Ctrl-C + a command + Enter hidden in a filename (CVE-class payload).
        let evil = "\u{03}rm -rf ~\u{0D}.txt"
        let out = FileDrop.payload(for: [evil])
        #expect(!out.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
    }

    @Test func aPathOfOnlyControlCharsIsDropped() {
        #expect(FileDrop.payload(for: ["\u{03}\u{0D}"]) == "")
        // ...and doesn't wipe out its valid neighbours.
        #expect(FileDrop.payload(for: ["\u{03}\u{0D}", "/a"]) == "/a ")
    }

    @Test func emptyInputProducesEmptyPayload() {
        #expect(FileDrop.payload(for: []) == "")
    }
}
