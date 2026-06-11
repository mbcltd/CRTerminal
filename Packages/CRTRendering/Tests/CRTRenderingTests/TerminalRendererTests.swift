import CoreGraphics
import CoreText
import Foundation
import Testing
import TerminalCore
@testable import CRTRendering

struct TerminalRendererTests {
    private func makeRenderer() -> TerminalRenderer? {
        TerminalRenderer(font: CTFontCreateWithName("Menlo" as CFString, 12, nil), scale: 1)
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        // bgra8 little-endian.
        return (data[offset + 2], data[offset + 1], data[offset])
    }

    @Test func rendersBackgroundAndGlyphs() throws {
        guard let renderer = makeRenderer() else { return } // no Metal device

        var terminal = Terminal(columns: 6, rows: 2)
        // "MM" in default colors, then two blue-background cells on row 1.
        terminal.feed(Array("MM\r\n\u{1B}[44m  ".utf8))
        let image = try #require(renderer.renderImage(terminal.state))

        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)

        // An untouched cell shows the default background.
        let bg = pixel(image, cellW * 4 + cellW / 2, cellH / 2)
        #expect(bg.r < 40 && bg.g < 40 && bg.b < 40)

        // A blue-eraseed cell (xterm blue 0,0,205) shows blue background.
        let blue = pixel(image, cellW / 2, cellH + cellH / 2)
        #expect(blue.b > 150)
        #expect(blue.r < 60 && blue.g < 60)

        // The 'M' cell contains at least one bright foreground pixel.
        var foundGlyphPixel = false
        for y in 0..<cellH {
            for x in 0..<cellW {
                let p = pixel(image, x, y)
                if p.r > 150 && p.g > 150 && p.b > 150 {
                    foundGlyphPixel = true
                }
            }
        }
        #expect(foundGlyphPixel)
    }

    @Test func cursorInvertsCell() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 4, rows: 1)
        terminal.feed(Array("a".utf8)) // cursor now over column 1, blank cell
        let image = try #require(renderer.renderImage(terminal.state))

        let cellW = Int(renderer.cellSize.width)
        let cellH = Int(renderer.cellSize.height)
        // Block cursor: cell 1 is filled with the (light) foreground color.
        let p = pixel(image, cellW + cellW / 2, cellH / 2)
        #expect(p.r > 150 && p.g > 150 && p.b > 150)
    }

    @Test func cellMetricsAreSane() throws {
        guard let renderer = makeRenderer() else { return }
        #expect(renderer.cellSize.width > 4)
        #expect(renderer.cellSize.height > 8)
    }
}
