import Foundation
import Testing
@testable import CRTerminal

struct FileDropTests {
    // MARK: Shell-prompt mode (not bracketed): escape + space + trailing space

    @Test func singleSimplePathPassesThroughWithTrailingSpace() {
        #expect(FileDrop.payload(for: ["/Users/dmb/notes.txt"], bracketedPaste: false)
            == "/Users/dmb/notes.txt ")
    }

    @Test func pathWithSpacesIsShellEscaped() {
        #expect(FileDrop.payload(for: ["/Users/dmb/My File.txt"], bracketedPaste: false)
            == "'/Users/dmb/My File.txt' ")
    }

    @Test func multiplePathsAreSpaceSeparatedAndEscaped() {
        let out = FileDrop.payload(
            for: ["/a/b.txt", "/c/d e.txt"], bracketedPaste: false)
        #expect(out == "/a/b.txt '/c/d e.txt' ")
    }

    @Test func shellMetacharactersAreQuoted() {
        // A path that would otherwise expand/execute at the prompt.
        let out = FileDrop.payload(for: ["/tmp/$(rm -rf ~).txt"], bracketedPaste: false)
        #expect(out == "'/tmp/$(rm -rf ~).txt' ")
    }

    @Test func embeddedSingleQuoteIsBrokenOut() {
        #expect(FileDrop.shellEscape("it's.txt") == "'it'\\''s.txt'")
    }

    // MARK: App mode (bracketed): raw paths, newline-separated, no quoting

    @Test func bracketedJoinsWithNewlinesAndDoesNotQuote() {
        let out = FileDrop.payload(
            for: ["/a/b.txt", "/c/d e.txt"], bracketedPaste: true)
        #expect(out == "/a/b.txt\n/c/d e.txt")
    }

    @Test func bracketedSinglePathHasNoTrailingSeparator() {
        #expect(FileDrop.payload(for: ["/a/b.txt"], bracketedPaste: true)
            == "/a/b.txt")
    }

    // MARK: Safety — control characters can never reach the line

    @Test func controlCharacterInjectionIsStripped() {
        // Ctrl-C + a command + Enter hidden in a filename (CVE-class payload).
        let evil = "\u{03}rm -rf ~\u{0D}.txt"
        let shell = FileDrop.payload(for: [evil], bracketedPaste: false)
        let app = FileDrop.payload(for: [evil], bracketedPaste: true)
        for out in [shell, app] {
            #expect(!out.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        }
    }

    @Test func aPathOfOnlyControlCharsIsDropped() {
        #expect(FileDrop.payload(for: ["\u{03}\u{0D}"], bracketedPaste: false) == "")
        // ...and doesn't wipe out its valid neighbours.
        #expect(FileDrop.payload(for: ["\u{03}\u{0D}", "/a"], bracketedPaste: false)
            == "/a ")
    }

    @Test func emptyInputProducesEmptyPayload() {
        #expect(FileDrop.payload(for: [], bracketedPaste: false) == "")
        #expect(FileDrop.payload(for: [], bracketedPaste: true) == "")
    }
}
