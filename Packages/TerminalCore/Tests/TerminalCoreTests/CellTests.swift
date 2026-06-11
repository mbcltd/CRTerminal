import Testing
@testable import TerminalCore

struct CellTests {
    @Test func cellStaysWithinSixteenByteStride() {
        #expect(MemoryLayout<Cell>.stride <= 16)
    }

    @Test func defaultColor() {
        let color = PackedColor.default
        #expect(color.isDefault)
        #expect(color.paletteIndex == nil)
        #expect(color.rgb == nil)
    }

    @Test(arguments: [UInt8(0), 15, 16, 231, 255])
    func paletteColorRoundTrips(index: UInt8) {
        let color = PackedColor.palette(index)
        #expect(color.paletteIndex == index)
        #expect(!color.isDefault)
        #expect(color.rgb == nil)
    }

    @Test func rgbColorRoundTrips() throws {
        let color = PackedColor.rgb(0x12, 0x34, 0x56)
        let rgb = try #require(color.rgb)
        #expect(rgb.red == 0x12)
        #expect(rgb.green == 0x34)
        #expect(rgb.blue == 0x56)
        #expect(!color.isDefault)
        #expect(color.paletteIndex == nil)
    }

    @Test func rgbBlackIsNotDefault() {
        #expect(!PackedColor.rgb(0, 0, 0).isDefault)
        #expect(PackedColor.rgb(0, 0, 0) != .default)
    }

    @Test func blankCellIsASpaceWithDefaultColors() {
        let blank = Cell.blank
        #expect(blank.glyph == 0x20)
        #expect(blank.foreground == .default)
        #expect(blank.background == .default)
        #expect(blank.attributes.isEmpty)
    }
}
