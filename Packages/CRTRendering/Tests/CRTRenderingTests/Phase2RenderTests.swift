import CoreGraphics
import CoreText
import Foundation
import Testing
import TerminalCore
@testable import CRTRendering

struct Phase2RenderTests {
    private func makeRenderer() -> TerminalRenderer? {
        RenderTestSupport.menlo()
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return (data[offset + 2], data[offset + 1], data[offset])
    }

    @Test func rpgPaintsBoldGoldNotBright() throws {
        // The RPG theme renders bold as a flat gold accent (#FFD23F) instead
        // of brightening — so a bold cell shows gold, a plain cell white.
        guard let renderer = RenderTestSupport.renderer(
            face: BundledFonts.pressStart2P, scale: 2) else { return }
        let rpg = try #require(CRTPresetLibrary.preset(named: "RPG"))
        var terminal = Terminal(columns: 2, rows: 1)
        terminal.feed(Array("\u{1B}[1mW\u{1B}[0mW".utf8)) // bold W, plain W
        let image = try #require(renderer.renderImage(terminal.state, preset: rpg))
        let cellW = Int(renderer.cellSize.width * renderer.scale)
        let cellH = Int(renderer.cellSize.height * renderer.scale)

        func hasGold(inCell col: Int) -> Bool {
            for y in 0..<cellH {
                for x in (col * cellW)..<min((col + 1) * cellW, image.width) {
                    let p = pixel(image, x, y)
                    if p.r > 200, p.g > 160, p.g < 230, p.b < 120 { return true }
                }
            }
            return false
        }
        func hasWhite(inCell col: Int) -> Bool {
            for y in 0..<cellH {
                for x in (col * cellW)..<min((col + 1) * cellW, image.width) {
                    let p = pixel(image, x, y)
                    if p.r > 220, p.g > 220, p.b > 220 { return true }
                }
            }
            return false
        }
        #expect(hasGold(inCell: 0))  // bold → gold
        #expect(hasWhite(inCell: 1)) // plain → white
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

    @Test func osc8LinkDrawsTightUnderline() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 3, rows: 1)
        // OSC 8 hyperlink wrapping a single space: the cell carries a link but
        // no glyph, so any foreground pixel is the link underline itself.
        // (Cursor lands on column 1; column 2 stays untouched.)
        terminal.feed(Array(
            "\u{1B}]8;;https://example.com\u{07} \u{1B}]8;;\u{07}".utf8))
        #expect(terminal.state.lines[0][0].link != 0)
        let image = try #require(renderer.renderImage(terminal.state))
        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        // Linked cell underlines; the untouched cell stays bare.
        var linked = false, bare = false
        for y in 0..<cellH {
            if pixel(image, cellW / 2, y).r > 150 { linked = true }
            if pixel(image, cellW * 2 + cellW / 2, y).r > 150 { bare = true }
        }
        #expect(linked)
        #expect(!bare)
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

    @Test func colorEmojiRendersInColor() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 4, rows: 1)
        terminal.feed(Array("\u{1B}[?25l😀".utf8))
        let image = try #require(renderer.renderImage(terminal.state))
        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        // The grinning-face emoji is saturated yellow: look for a pixel where
        // red and green clearly dominate blue (a tinted gray glyph can't).
        var foundColor = false
        for y in 0..<cellH {
            for x in 0..<(cellW * 2) {
                let p = pixel(image, x, y)
                if p.r > 180 && p.g > 130 && p.b < 100 { foundColor = true }
            }
        }
        #expect(foundColor)
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

    @Test func osc4PaletteOverrideWinsOverPreset() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 2, rows: 1)
        // Paint a cell with ANSI background 1 (palette slot 1 = red in the
        // preset), then override that slot to pure blue via OSC 4. The runtime
        // override must win over the preset palette (issue #25).
        terminal.feed(Array(
            "\u{1B}]4;1;rgb:0000/0000/ffff\u{1B}\\\u{1B}[41m \u{1B}[0m".utf8))
        let image = try #require(renderer.renderImage(terminal.state))
        let cellH = Int(renderer.cellSize.height)
        let p = pixel(image, 1, cellH / 2)
        #expect(p.b > 150 && p.r < 80) // blue override, not the preset red
    }

    @Test func osc11BackgroundOverrideFillsScreen() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 2, rows: 1)
        // OSC 11 sets the default background to pure blue; the (default-bg)
        // cells must paint with it.
        terminal.feed(Array("\u{1B}]11;rgb:0000/0000/ffff\u{1B}\\".utf8))
        let image = try #require(renderer.renderImage(terminal.state))
        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        let p = pixel(image, cellW + cellW / 2, cellH / 2) // a bare cell
        #expect(p.b > 150 && p.r < 80)
    }
}
