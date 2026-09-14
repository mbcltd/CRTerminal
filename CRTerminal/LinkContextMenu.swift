import Foundation

/// The link-specific rows of the terminal's right-click menu, kept free of
/// AppKit so the wording and action set can be unit-tested. `TerminalView`
/// turns each `Item` into an `NSMenuItem` whose `representedObject` is the URL.
enum LinkContextMenu {
    enum Action: Equatable {
        /// Hand the URL to Launch Services (browser, default app for a file).
        case open
        /// Select the file in a Finder window.
        case revealInFinder
        /// Put the URL (or, for files, the plain path) on the pasteboard.
        case copy
    }

    struct Item: Equatable {
        var title: String
        var action: Action
    }

    /// Rows to show for the link under the pointer: nothing when there is no
    /// link, Open/Copy for web-style URLs, and Open/Reveal/Copy Path for
    /// local files so the wording says what will actually happen.
    static func items(for url: URL?) -> [Item] {
        guard let url else { return [] }
        if url.isFileURL {
            let name = url.lastPathComponent
            let hasName = !name.isEmpty && name != "/"
            let openTitle = hasName ? "Open “\(name)”" : "Open"
            return [
                Item(title: openTitle, action: .open),
                Item(title: "Reveal in Finder", action: .revealInFinder),
                Item(title: "Copy Path", action: .copy),
            ]
        }
        return [
            Item(title: "Open Link", action: .open),
            Item(title: "Copy Link", action: .copy),
        ]
    }

    /// What "Copy Link"/"Copy Path" puts on the pasteboard: the bare path for
    /// files (pasteable straight into a shell), the full URL otherwise.
    static func pasteboardText(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }
}
