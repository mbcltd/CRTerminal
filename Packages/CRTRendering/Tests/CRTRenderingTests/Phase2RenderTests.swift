import CoreGraphics
import CoreText
import Foundation
import Testing
import TerminalCore
@testable import CRTRendering

struct Phase2RenderTests {
    private func makeRenderer() -> TerminalRenderer? {
        TerminalRenderer(font: CTFontCreateWithName("Menlo" as CFString, 12, nil), scale: 1)
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return (data[offset + 2], data[offset + 1], data[offset])
    }

    @Test func scrolledViewportShowsScrollback() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 4, rows: 2)
        // Blue-background line scrolls into scrollback.
        terminal.feed(Array("\u{1B}[44m  \u{1B}[0m\r\na\r\nb\r\nc".utf8))
        #expect(terminal.state.scrollback.count == 2)

        let live = try #require(renderer.renderImage(terminal.state))
        let cellH = Int(renderer.cellSize.height)
        let topLive = pixel(live, 2, cellH / 2)
        #expect(topLive.b < 100) // blue line is off-screen when live

        let back = try #require(renderer.renderImage(terminal.state, scrollOffset: 2))
        let topBack = pixel(back, 2, cellH / 2)
        #expect(topBack.b > 150) // scrolled back: blue line visible
    }

    @Test func selectionHighlightsCells() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 4, rows: 1)
        terminal.feed(Array("ab".utf8))
        let top = terminal.state.absoluteScreenTop
        let selection = Selection(
            anchor: SelectionPoint(row: top, column: 0),
            head: SelectionPoint(row: top, column: 1))
        let image = try #require(renderer.renderImage(terminal.state, selection: selection))
        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        // Corner of a selected cell shows the selection background.
        let selectedCorner = pixel(image, 1, 1)
        #expect(selectedCorner.b > 80 && selectedCorner.b < 160)
        // Unselected cell (column 3) keeps the default background.
        let unselected = pixel(image, cellW * 3 + cellW / 2, cellH / 2)
        #expect(unselected.b < 40)
    }

    @Test func underlineDrawsBelowGlyph() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 2, rows: 1)
        terminal.feed(Array("\u{1B}[4m \u{1B}[0m".utf8)) // underlined space
        let image = try #require(renderer.renderImage(terminal.state))
        var found = false
        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        for y in (cellH / 2)..<cellH {
            let p = pixel(image, cellW / 2, y)
            if p.r > 150 { found = true }
        }
        #expect(found)
    }

    @Test func barCursorDrawsThinLine() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 4, rows: 1)
        terminal.feed(Array("\u{1B}[5 q".utf8)) // bar cursor at cell 0
        let image = try #require(renderer.renderImage(terminal.state))
        let cellH = Int(renderer.cellSize.height)
        let cellW = Int(renderer.cellSize.width)
        let left = pixel(image, 0, cellH / 2)
        #expect(left.r > 150) // bar at left edge
        let middle = pixel(image, cellW / 2 + 1, cellH / 2)
        #expect(middle.r < 100) // not a block cursor
    }

    @Test func wideGlyphRendersAcrossTwoCells() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 4, rows: 1)
        terminal.feed(Array("\u{1B}[?25l中".utf8))
        let image = try #require(renderer.renderImage(terminal.state))
        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        // Ink should appear in the second cell (right half of the glyph).
        var found = false
        for y in 0..<cellH {
            for x in cellW..<(cellW * 2) {
                let p = pixel(image, x, y)
                if p.r > 100 { found = true }
            }
        }
        #expect(found)
    }
}
