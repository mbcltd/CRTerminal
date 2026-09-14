import Foundation
import Testing
@testable import CRTerminal

struct LinkContextMenuTests {
    @Test func noLinkMeansNoLinkRows() {
        #expect(LinkContextMenu.items(for: nil).isEmpty)
    }

    @Test func webURLsGetOpenAndCopyLink() {
        let url = URL(string: "https://example.com/path?q=1")!
        #expect(LinkContextMenu.items(for: url) == [
            .init(title: "Open Link", action: .open),
            .init(title: "Copy Link", action: .copy),
        ])
        #expect(LinkContextMenu.pasteboardText(for: url) == "https://example.com/path?q=1")
    }

    @Test func fileURLsGetOpenRevealAndCopyPath() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        #expect(LinkContextMenu.items(for: url) == [
            .init(title: "Open “notes.txt”", action: .open),
            .init(title: "Reveal in Finder", action: .revealInFinder),
            .init(title: "Copy Path", action: .copy),
        ])
        // The copied text is the bare path, ready to paste into a shell.
        #expect(LinkContextMenu.pasteboardText(for: url) == "/tmp/notes.txt")
    }

    @Test func rootPathHasNoNameToQuote() {
        let items = LinkContextMenu.items(for: URL(fileURLWithPath: "/"))
        #expect(items.first?.title == "Open")
    }
}
