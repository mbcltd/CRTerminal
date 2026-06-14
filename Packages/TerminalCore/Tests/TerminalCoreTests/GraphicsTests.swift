import Foundation
import Testing
@testable import TerminalCore

private func makeTerminal(columns: Int = 20, rows: Int = 10) -> Terminal {
    var t = Terminal(columns: columns, rows: rows)
    t.setCellPixelSize(width: 10, height: 20)
    return t
}

private func base64(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
}

/// A minimal valid PNG header (signature + IHDR width/height) — enough for the
/// core's header-only dimension probe.
private func pngHeader(width: Int, height: Int) -> [UInt8] {
    var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] // signature
    b += [0, 0, 0, 13]                                                 // IHDR length
    b += Array("IHDR".utf8)
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    b += be(width) + be(height)
    b += [8, 6, 0, 0, 0] // bit depth, color type, etc.
    return b
}

struct KittyGraphicsTests {
    @Test func transmitAndDisplayRGBA() {
        var t = makeTerminal()
        let pixels = [UInt8](repeating: 0xFF, count: 4 * 4 * 4) // 4×4 RGBA
        t.feed(Array("\u{1B}_Gf=32,s=4,v=4,a=T,i=1;\(base64(pixels))\u{1B}\\".utf8))

        #expect(t.state.images.count == 1)
        let image = t.state.images.values.first!
        #expect(image.format == .rgba)
        #expect(image.pixelWidth == 4 && image.pixelHeight == 4)
        #expect(t.state.imagePlacements.count == 1)
        // 4px / 10px cell width → 1 col; 4px / 20px cell height → 1 row.
        #expect(t.state.imagePlacements[0].columns == 1)
        #expect(t.state.imagePlacements[0].rows == 1)
        // Cursor moved below the image.
        #expect(t.state.cursor.y == 1)
    }

    @Test func transmitRespondsOK() {
        var t = makeTerminal()
        let pixels = [UInt8](repeating: 0, count: 4)
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=t,i=7;\(base64(pixels))\u{1B}\\".utf8))
        let response = String(decoding: t.drainResponses(), as: UTF8.self)
        #expect(response.contains("i=7"))
        #expect(response.contains("OK"))
    }

    @Test func quietSuppressesOK() {
        var t = makeTerminal()
        let pixels = [UInt8](repeating: 0, count: 4)
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=t,i=7,q=1;\(base64(pixels))\u{1B}\\".utf8))
        #expect(t.drainResponses().isEmpty)
    }

    @Test func chunkedTransmission() {
        var t = makeTerminal()
        let pixels = [UInt8](repeating: 0xAB, count: 2 * 2 * 4)
        let b64 = base64(pixels)
        let mid = b64.index(b64.startIndex, offsetBy: b64.count / 2)
        let first = String(b64[..<mid])
        let second = String(b64[mid...])
        t.feed(Array("\u{1B}_Gf=32,s=2,v=2,a=T,i=3,m=1;\(first)\u{1B}\\".utf8))
        #expect(t.state.images.isEmpty) // still buffering
        t.feed(Array("\u{1B}_Gm=0;\(second)\u{1B}\\".utf8))
        #expect(t.state.images.count == 1)
        #expect(t.state.images.values.first!.bytes == pixels)
    }

    @Test func displayExistingByID() {
        var t = makeTerminal()
        let pixels = [UInt8](repeating: 0, count: 4)
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=t,i=42;\(base64(pixels))\u{1B}\\".utf8))
        #expect(t.state.imagePlacements.isEmpty) // transmit only
        t.feed(Array("\u{1B}_Ga=p,i=42,c=3,r=2;\u{1B}\\".utf8))
        #expect(t.state.imagePlacements.count == 1)
        #expect(t.state.imagePlacements[0].columns == 3)
        #expect(t.state.imagePlacements[0].rows == 2)
    }

    @Test func deleteAllPlacements() {
        var t = makeTerminal()
        let pixels = [UInt8](repeating: 0, count: 4)
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=T,i=1;\(base64(pixels))\u{1B}\\".utf8))
        #expect(t.state.imagePlacements.count == 1)
        t.feed(Array("\u{1B}_Ga=d,d=a;\u{1B}\\".utf8))
        #expect(t.state.imagePlacements.isEmpty)
        #expect(t.state.images.count == 1) // lowercase keeps image data
    }

    @Test func pngFormatReadsHeaderDimensions() {
        var t = makeTerminal()
        let png = pngHeader(width: 30, height: 40)
        t.feed(Array("\u{1B}_Gf=100,a=T,i=1;\(base64(png))\u{1B}\\".utf8))
        let image = t.state.images.values.first
        #expect(image?.pixelWidth == 30)
        #expect(image?.pixelHeight == 40)
        #expect(image?.format == .encoded)
    }
}

struct SixelTests {
    @Test func decodesSimpleColumn() {
        var t = makeTerminal()
        // Define color 0 as red (RGB), then '~' = all six pixels set.
        t.feed(Array("\u{1B}P0;0;0q#0;2;100;0;0~\u{1B}\\".utf8))
        #expect(t.state.images.count == 1)
        let image = t.state.images.values.first!
        #expect(image.format == .rgba)
        #expect(image.pixelWidth == 1)
        #expect(image.pixelHeight == 6)
        // Top pixel is red, opaque.
        #expect(image.bytes[0] == 255 && image.bytes[1] == 0 && image.bytes[2] == 0)
        #expect(image.bytes[3] == 255)
        #expect(t.state.imagePlacements.count == 1)
    }

    @Test func repeatExpandsWidth() {
        var t = makeTerminal()
        t.feed(Array("\u{1B}P0;0;0q#0;2;0;100;0!5~\u{1B}\\".utf8))
        let image = t.state.images.values.first!
        #expect(image.pixelWidth == 5)
        #expect(image.pixelHeight == 6)
    }

    @Test func newlineAddsBand() {
        var t = makeTerminal()
        t.feed(Array("\u{1B}P0;0;0q#0;2;0;0;100~-~\u{1B}\\".utf8))
        let image = t.state.images.values.first!
        #expect(image.pixelHeight == 12) // two 6-px bands
    }
}

struct ITermImageTests {
    @Test func inlineImageCreatesPlacement() {
        var t = makeTerminal()
        let png = pngHeader(width: 40, height: 40)
        t.feed(Array("\u{1B}]1337;File=inline=1;width=4:\(base64(png))\u{07}".utf8))
        #expect(t.state.images.count == 1)
        let placement = t.state.imagePlacements.first
        #expect(placement?.columns == 4)
        // Aspect preserved: 40×40 image, cells 10×20 → square in px means
        // 4 cols (40px) ↔ 2 rows (40px / 20px-cell).
        #expect(placement?.rows == 2)
    }

    @Test func nonInlineIgnored() {
        var t = makeTerminal()
        let png = pngHeader(width: 10, height: 10)
        t.feed(Array("\u{1B}]1337;File=inline=0;width=4:\(base64(png))\u{07}".utf8))
        #expect(t.state.images.isEmpty)
    }
}

struct ImageEvictionTests {
    @Test func placementScrollsOffWithScrollback() {
        var t = makeTerminal(columns: 10, rows: 3)
        t.scrollbackLimit = 2
        let pixels = [UInt8](repeating: 0, count: 4)
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=T,i=1;\(base64(pixels))\u{1B}\\".utf8))
        #expect(t.state.imagePlacements.count == 1)
        // Trimming has a 1024-line hysteresis; push well past it so the
        // anchor row (0) is actually evicted from scrollback.
        for _ in 0..<1100 { t.feed(Array("x\r\n".utf8)) }
        #expect(t.state.evictedLineCount > 0)
        #expect(t.state.imagePlacements.isEmpty)
    }

    @Test func clearRemovesOnScreenImages() {
        var t = makeTerminal(columns: 20, rows: 10)
        let pixels = [UInt8](repeating: 0, count: 4)
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=T,i=1;\(base64(pixels))\u{1B}\\".utf8))
        #expect(t.state.imagePlacements.count == 1)
        // ED(2) — what `clear` emits — must take the image with it.
        t.feed(Array("\u{1B}[2J".utf8))
        #expect(t.state.imagePlacements.isEmpty)
    }

    @Test func eraseBelowCursorKeepsImageAboveCursor() {
        var t = makeTerminal(columns: 20, rows: 10)
        let pixels = [UInt8](repeating: 0, count: 4)
        // Image at row 0; cursor advances to row 1.
        t.feed(Array("\u{1B}_Gf=32,s=1,v=1,a=T,i=1;\(base64(pixels))\u{1B}\\".utf8))
        // Move to row 5, then ED(0) erases from there down — image stays.
        t.feed(Array("\u{1B}[6;1H\u{1B}[0J".utf8))
        #expect(t.state.imagePlacements.count == 1)
    }

    @Test func reportsCellSizeForCSI16t() {
        var t = makeTerminal()
        t.setCellPixelSize(width: 9, height: 18)
        t.feed(Array("\u{1B}[16t".utf8))
        let response = String(decoding: t.drainResponses(), as: UTF8.self)
        #expect(response == "\u{1B}[6;18;9t")
    }
}
