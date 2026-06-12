import CoreGraphics
import Testing
@testable import CRTRendering

/// Renders a scalar into a bare cell-sized gray bitmap. Memory is
/// top-row-first (matching the atlas), so `pixels[0]` is the top-left pixel.
private func render(_ scalar: UInt32, width: Int = 16, height: Int = 32) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        BoxDrawing.draw(scalar, in: context, width: width, height: height)
    }
    return pixels
}

struct BoxDrawingTests {
    let width = 16, height = 32

    @Test func coversBoxAndBlockRangesOnly() {
        #expect(BoxDrawing.covers(0x2500))
        #expect(BoxDrawing.covers(0x259F))
        #expect(!BoxDrawing.covers(0x24FF))
        #expect(!BoxDrawing.covers(0x25A0)) // ■ geometric shapes stay font glyphs
    }

    @Test func fullBlockFillsEveryPixel() {
        #expect(render(0x2588).allSatisfy { $0 == 255 })
    }

    @Test func everyCharacterProducesInk() {
        for scalar in UInt32(0x2500)...0x259F {
            #expect(render(scalar).contains { $0 > 0 },
                    "U+\(String(scalar, radix: 16)) rendered blank")
        }
    }

    @Test func leftAndRightHalvesTileExactly() {
        let left = render(0x258C), right = render(0x2590)
        for i in left.indices {
            #expect(left[i] == 255 || right[i] == 255, "gap at \(i)")
            #expect(!(left[i] == 255 && right[i] == 255), "overlap at \(i)")
        }
    }

    @Test func upperAndLowerHalvesTileExactly() {
        let upper = render(0x2580), lower = render(0x2584)
        for i in upper.indices {
            #expect(upper[i] == 255 || lower[i] == 255, "gap at \(i)")
            #expect(!(upper[i] == 255 && lower[i] == 255), "overlap at \(i)")
        }
    }

    @Test func upperHalfIsTopRowsInAtlasOrientation() {
        let upper = render(0x2580)
        #expect(upper[0] == 255)                          // top-left filled
        #expect(upper[(height - 1) * width] == 0)         // bottom-left empty
    }

    @Test func quadrantsPartitionTheCell() {
        let quads = [0x2598, 0x259D, 0x2596, 0x2597].map { render(UInt32($0)) }
        for i in 0..<(width * height) {
            let covered = quads.filter { $0[i] == 255 }.count
            #expect(covered == 1, "pixel \(i) covered by \(covered) quadrants")
        }
    }

    @Test func eighthsStackWithoutGaps() {
        // ▁ through █ are nested; each adds rows at the top of the previous.
        var previous = 0
        for scalar in UInt32(0x2581)...0x2588 {
            let filled = render(scalar).count { $0 == 255 }
            #expect(filled > previous, "U+\(String(scalar, radix: 16)) not taller")
            previous = filled
        }
        #expect(previous == width * height)
    }

    @Test func shadesAreUniformCoverage() {
        for (scalar, expected) in [(UInt32(0x2591), 64), (0x2592, 128), (0x2593, 191)] {
            let pixels = render(scalar)
            let value = Int(pixels[0])
            #expect(abs(value - expected) <= 2, "U+\(String(scalar, radix: 16))")
            #expect(pixels.allSatisfy { Int($0) == value })
        }
    }

    @Test func lightHorizontalSpansFullWidth() {
        let pixels = render(0x2500)
        var inkRows = 0
        for y in 0..<height {
            let row = pixels[(y * width)..<((y + 1) * width)]
            if row.contains(where: { $0 > 0 }) {
                inkRows += 1
                #expect(row.allSatisfy { $0 == 255 }, "row \(y) has a gap")
            }
        }
        #expect(inkRows == 2) // light = max(1, round(16 / 8))
    }

    @Test func lightVerticalSpansFullHeight() {
        let pixels = render(0x2502)
        for y in 0..<height {
            let row = pixels[(y * width)..<((y + 1) * width)]
            #expect(row.contains { $0 == 255 }, "row \(y) empty")
        }
    }

    @Test func heavyIsThickerThanLight() {
        let light = render(0x2500).count { $0 > 0 }
        let heavy = render(0x2501).count { $0 > 0 }
        #expect(heavy == light * 2)
    }

    @Test func doubleVerticalHasTwoSeparatedLines() {
        let pixels = render(0x2551)
        let row = pixels[0..<width]
        let segments = row.reduce(into: (count: 0, inInk: false)) { state, value in
            let ink = value == 255
            if ink && !state.inInk { state.count += 1 }
            state.inInk = ink
        }
        #expect(segments.count == 2)
    }

    @Test func cornersTouchBothEdges() {
        // ┌ must reach the right and bottom cell edges exactly so it meets
        // its neighbors (top row in atlas orientation is the cell top).
        let pixels = render(0x250C)
        let lastRow = pixels[((height - 1) * width)...]
        #expect(lastRow.contains { $0 == 255 }, "down arm misses bottom edge")
        let rightColumn = stride(from: width - 1, to: width * height, by: width)
        #expect(rightColumn.contains { pixels[$0] == 255 }, "right arm misses edge")
    }
}
