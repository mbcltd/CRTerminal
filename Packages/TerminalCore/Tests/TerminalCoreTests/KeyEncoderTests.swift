import Testing
@testable import TerminalCore

struct KeyEncoderTests {
    @Test func arrowsNormalMode() {
        #expect(KeyEncoder.encode(.up) == Array("\u{1B}[A".utf8))
        #expect(KeyEncoder.encode(.left) == Array("\u{1B}[D".utf8))
    }

    @Test func arrowsApplicationMode() {
        #expect(KeyEncoder.encode(.up, applicationCursorKeys: true) == Array("\u{1B}OA".utf8))
    }

    @Test func modifiedArrowIgnoresApplicationMode() {
        let bytes = KeyEncoder.encode(.right, modifiers: [.control], applicationCursorKeys: true)
        #expect(bytes == Array("\u{1B}[1;5C".utf8))
    }

    @Test func shiftedArrow() {
        #expect(KeyEncoder.encode(.up, modifiers: [.shift]) == Array("\u{1B}[1;2A".utf8))
    }

    @Test func editingKeys() {
        #expect(KeyEncoder.encode(.enter) == [0x0D])
        #expect(KeyEncoder.encode(.backspace) == [0x7F])
        #expect(KeyEncoder.encode(.tab) == [0x09])
        #expect(KeyEncoder.encode(.tab, modifiers: [.shift]) == Array("\u{1B}[Z".utf8))
        #expect(KeyEncoder.encode(.escape) == [0x1B])
        #expect(KeyEncoder.encode(.deleteForward) == Array("\u{1B}[3~".utf8))
        #expect(KeyEncoder.encode(.pageUp) == Array("\u{1B}[5~".utf8))
    }

    @Test func controlCharacters() {
        #expect(KeyEncoder.encodeControl("c") == 0x03)
        #expect(KeyEncoder.encodeControl("C") == 0x03)
        #expect(KeyEncoder.encodeControl("[") == 0x1B)
        #expect(KeyEncoder.encodeControl("@") == 0x00)
        #expect(KeyEncoder.encodeControl("é") == nil)
    }

    @Test func functionKeys() {
        #expect(KeyEncoder.encode(.function(1)) == Array("\u{1B}OP".utf8))
        #expect(KeyEncoder.encode(.function(5)) == Array("\u{1B}[15~".utf8))
        #expect(KeyEncoder.encode(.function(12)) == Array("\u{1B}[24~".utf8))
    }

    @Test func pasteBracketedAndPlain() {
        #expect(KeyEncoder.encodePaste("hi\n2", bracketed: false) == Array("hi\r2".utf8))
        #expect(KeyEncoder.encodePaste("x", bracketed: true) == Array("\u{1B}[200~x\u{1B}[201~".utf8))
    }
}
