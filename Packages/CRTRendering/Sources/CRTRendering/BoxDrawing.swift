import CoreGraphics

/// Procedural geometry for the Unicode Box Drawing (U+2500–257F) and Block
/// Elements (U+2580–259F) ranges. Font glyphs for these characters rarely
/// fill the (rounded-up) cell exactly — and may come from a fallback font
/// with foreign metrics — leaving background seams in TUI borders and block
/// art. Like every mature terminal, we never consult the font for these:
/// they are drawn from the actual cell geometry, pixel-snapped so adjacent
/// cells tile seamlessly.
enum BoxDrawing {
    static func covers(_ scalar: UInt32) -> Bool {
        (0x2500...0x259F).contains(scalar)
    }

    /// Draws `scalar` as white coverage into `context`, an 8-bit gray bitmap
    /// whose (0,0)-(width,height) region (CG bottom-left origin) is exactly
    /// one cell.
    static func draw(
        _ scalar: UInt32, in context: CGContext,
        width: Int, height: Int
    ) {
        let m = Metrics(width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(gray: 1, alpha: 1)
        context.setShouldAntialias(false)

        switch scalar {
        case 0x2580...0x259F:
            blockElement(scalar, m, context)
        case 0x2504...0x250B, 0x254C...0x254F:
            dashed(scalar, m, context)
        case 0x2550...0x256C:
            doubleLines(scalar, m, context)
        case 0x256D...0x2570:
            arc(scalar, m, context)
        case 0x2571...0x2573:
            diagonal(scalar, m, context)
        default:
            if let arms = armTable(scalar) {
                drawArms(arms, m, context)
            }
        }
    }

    // MARK: Metrics

    private struct Metrics {
        let w, h, cx, cy: CGFloat
        /// Light/heavy stroke thicknesses and the double-line center offset,
        /// all whole pixels so strokes land on the pixel grid.
        let light, heavy, gap: CGFloat

        init(width: CGFloat, height: CGFloat) {
            w = width
            h = height
            cx = width / 2
            cy = height / 2
            light = max(1, (width / 8).rounded())
            heavy = light * 2
            gap = max(light, (width / 6).rounded())
        }
    }

    /// Horizontal band centered on y, pixel-snapped.
    private static func hline(
        _ ctx: CGContext, y: CGFloat, from x0: CGFloat, to x1: CGFloat,
        thickness t: CGFloat
    ) {
        let left = x0.rounded()
        ctx.fill(CGRect(
            x: left, y: (y - t / 2).rounded(),
            width: x1.rounded() - left, height: t))
    }

    /// Vertical band centered on x, pixel-snapped.
    private static func vline(
        _ ctx: CGContext, x: CGFloat, from y0: CGFloat, to y1: CGFloat,
        thickness t: CGFloat
    ) {
        let bottom = y0.rounded()
        ctx.fill(CGRect(
            x: (x - t / 2).rounded(), y: bottom,
            width: t, height: y1.rounded() - bottom))
    }

    // MARK: Single/heavy line characters (arm combinations)

    private struct Arms {
        var left = 0, right = 0, up = 0, down = 0 // 0 none, 1 light, 2 heavy
        init(_ l: Int, _ r: Int, _ u: Int, _ d: Int) {
            (left, right, up, down) = (l, r, u, d)
        }
    }

    private static func drawArms(_ a: Arms, _ m: Metrics, _ ctx: CGContext) {
        func t(_ weight: Int) -> CGFloat { weight == 2 ? m.heavy : m.light }
        // Arms overlap the crossing line's half-thickness so joints are solid.
        let vmax = max(a.up > 0 ? t(a.up) : 0, a.down > 0 ? t(a.down) : 0)
        let hmax = max(a.left > 0 ? t(a.left) : 0, a.right > 0 ? t(a.right) : 0)
        if a.left > 0 {
            hline(ctx, y: m.cy, from: 0, to: m.cx + vmax / 2, thickness: t(a.left))
        }
        if a.right > 0 {
            hline(ctx, y: m.cy, from: m.cx - vmax / 2, to: m.w, thickness: t(a.right))
        }
        if a.up > 0 {
            vline(ctx, x: m.cx, from: m.cy - hmax / 2, to: m.h, thickness: t(a.up))
        }
        if a.down > 0 {
            vline(ctx, x: m.cx, from: 0, to: m.cy + hmax / 2, thickness: t(a.down))
        }
    }

    /// (left, right, up, down) weights for U+2500–254B and U+2574–257F.
    private static func armTable(_ scalar: UInt32) -> Arms? {
        switch scalar {
        case 0x2500: return Arms(1, 1, 0, 0)
        case 0x2501: return Arms(2, 2, 0, 0)
        case 0x2502: return Arms(0, 0, 1, 1)
        case 0x2503: return Arms(0, 0, 2, 2)
        case 0x250C: return Arms(0, 1, 0, 1)
        case 0x250D: return Arms(0, 2, 0, 1)
        case 0x250E: return Arms(0, 1, 0, 2)
        case 0x250F: return Arms(0, 2, 0, 2)
        case 0x2510: return Arms(1, 0, 0, 1)
        case 0x2511: return Arms(2, 0, 0, 1)
        case 0x2512: return Arms(1, 0, 0, 2)
        case 0x2513: return Arms(2, 0, 0, 2)
        case 0x2514: return Arms(0, 1, 1, 0)
        case 0x2515: return Arms(0, 2, 1, 0)
        case 0x2516: return Arms(0, 1, 2, 0)
        case 0x2517: return Arms(0, 2, 2, 0)
        case 0x2518: return Arms(1, 0, 1, 0)
        case 0x2519: return Arms(2, 0, 1, 0)
        case 0x251A: return Arms(1, 0, 2, 0)
        case 0x251B: return Arms(2, 0, 2, 0)
        case 0x251C: return Arms(0, 1, 1, 1)
        case 0x251D: return Arms(0, 2, 1, 1)
        case 0x251E: return Arms(0, 1, 2, 1)
        case 0x251F: return Arms(0, 1, 1, 2)
        case 0x2520: return Arms(0, 1, 2, 2)
        case 0x2521: return Arms(0, 2, 2, 1)
        case 0x2522: return Arms(0, 2, 1, 2)
        case 0x2523: return Arms(0, 2, 2, 2)
        case 0x2524: return Arms(1, 0, 1, 1)
        case 0x2525: return Arms(2, 0, 1, 1)
        case 0x2526: return Arms(1, 0, 2, 1)
        case 0x2527: return Arms(1, 0, 1, 2)
        case 0x2528: return Arms(1, 0, 2, 2)
        case 0x2529: return Arms(2, 0, 2, 1)
        case 0x252A: return Arms(2, 0, 1, 2)
        case 0x252B: return Arms(2, 0, 2, 2)
        case 0x252C: return Arms(1, 1, 0, 1)
        case 0x252D: return Arms(2, 1, 0, 1)
        case 0x252E: return Arms(1, 2, 0, 1)
        case 0x252F: return Arms(2, 2, 0, 1)
        case 0x2530: return Arms(1, 1, 0, 2)
        case 0x2531: return Arms(2, 1, 0, 2)
        case 0x2532: return Arms(1, 2, 0, 2)
        case 0x2533: return Arms(2, 2, 0, 2)
        case 0x2534: return Arms(1, 1, 1, 0)
        case 0x2535: return Arms(2, 1, 1, 0)
        case 0x2536: return Arms(1, 2, 1, 0)
        case 0x2537: return Arms(2, 2, 1, 0)
        case 0x2538: return Arms(1, 1, 2, 0)
        case 0x2539: return Arms(2, 1, 2, 0)
        case 0x253A: return Arms(1, 2, 2, 0)
        case 0x253B: return Arms(2, 2, 2, 0)
        case 0x253C: return Arms(1, 1, 1, 1)
        case 0x253D: return Arms(2, 1, 1, 1)
        case 0x253E: return Arms(1, 2, 1, 1)
        case 0x253F: return Arms(2, 2, 1, 1)
        case 0x2540: return Arms(1, 1, 2, 1)
        case 0x2541: return Arms(1, 1, 1, 2)
        case 0x2542: return Arms(1, 1, 2, 2)
        case 0x2543: return Arms(2, 1, 2, 1)
        case 0x2544: return Arms(1, 2, 2, 1)
        case 0x2545: return Arms(2, 1, 1, 2)
        case 0x2546: return Arms(1, 2, 1, 2)
        case 0x2547: return Arms(2, 2, 2, 1)
        case 0x2548: return Arms(2, 2, 1, 2)
        case 0x2549: return Arms(2, 1, 2, 2)
        case 0x254A: return Arms(1, 2, 2, 2)
        case 0x254B: return Arms(2, 2, 2, 2)
        case 0x2574: return Arms(1, 0, 0, 0)
        case 0x2575: return Arms(0, 0, 1, 0)
        case 0x2576: return Arms(0, 1, 0, 0)
        case 0x2577: return Arms(0, 0, 0, 1)
        case 0x2578: return Arms(2, 0, 0, 0)
        case 0x2579: return Arms(0, 0, 2, 0)
        case 0x257A: return Arms(0, 2, 0, 0)
        case 0x257B: return Arms(0, 0, 0, 2)
        case 0x257C: return Arms(1, 2, 0, 0)
        case 0x257D: return Arms(0, 0, 1, 2)
        case 0x257E: return Arms(2, 1, 0, 0)
        case 0x257F: return Arms(0, 0, 2, 1)
        default: return nil
        }
    }

    // MARK: Dashed lines

    private static func dashed(_ scalar: UInt32, _ m: Metrics, _ ctx: CGContext) {
        let (count, weight, vertical): (Int, Int, Bool)
        switch scalar {
        case 0x2504: (count, weight, vertical) = (3, 1, false)
        case 0x2505: (count, weight, vertical) = (3, 2, false)
        case 0x2506: (count, weight, vertical) = (3, 1, true)
        case 0x2507: (count, weight, vertical) = (3, 2, true)
        case 0x2508: (count, weight, vertical) = (4, 1, false)
        case 0x2509: (count, weight, vertical) = (4, 2, false)
        case 0x250A: (count, weight, vertical) = (4, 1, true)
        case 0x250B: (count, weight, vertical) = (4, 2, true)
        case 0x254C: (count, weight, vertical) = (2, 1, false)
        case 0x254D: (count, weight, vertical) = (2, 2, false)
        case 0x254E: (count, weight, vertical) = (2, 1, true)
        case 0x254F: (count, weight, vertical) = (2, 2, true)
        default: return
        }
        let t = weight == 2 ? m.heavy : m.light
        let span = vertical ? m.h : m.w
        let segment = span / CGFloat(count)
        let inset = max(1, (segment / 6).rounded())
        for i in 0..<count {
            let from = segment * CGFloat(i) + inset
            let to = segment * CGFloat(i + 1) - inset
            if vertical {
                vline(ctx, x: m.cx, from: from, to: to, thickness: t)
            } else {
                hline(ctx, y: m.cy, from: from, to: to, thickness: t)
            }
        }
    }

    // MARK: Double lines (U+2550–256C)

    private static func doubleLines(_ scalar: UInt32, _ m: Metrics, _ ctx: CGContext) {
        let t = m.light
        let e = t / 2 // joint closure: segments overlap crossing lines
        // Parallel line center positions (CG y-up: yT is the visually upper).
        let xL = m.cx - m.gap, xR = m.cx + m.gap
        let yT = m.cy + m.gap, yB = m.cy - m.gap
        func h(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) {
            hline(ctx, y: y, from: x0, to: x1, thickness: t)
        }
        func v(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            vline(ctx, x: x, from: y0, to: y1, thickness: t)
        }

        switch scalar {
        case 0x2550: h(yT, 0, m.w); h(yB, 0, m.w)                              // ═
        case 0x2551: v(xL, 0, m.h); v(xR, 0, m.h)                              // ║
        case 0x2552: v(m.cx, 0, yT + e); h(yT, m.cx - e, m.w); h(yB, m.cx - e, m.w) // ╒
        case 0x2553: v(xL, 0, m.cy + e); v(xR, 0, m.cy + e); h(m.cy, xL - e, m.w)   // ╓
        case 0x2554:                                                           // ╔
            h(yT, xL - e, m.w); h(yB, xR - e, m.w)
            v(xL, 0, yT + e); v(xR, 0, yB + e)
        case 0x2555: v(m.cx, 0, yT + e); h(yT, 0, m.cx + e); h(yB, 0, m.cx + e) // ╕
        case 0x2556: v(xL, 0, m.cy + e); v(xR, 0, m.cy + e); h(m.cy, 0, xR + e) // ╖
        case 0x2557:                                                           // ╗
            h(yT, 0, xR + e); h(yB, 0, xL + e)
            v(xR, 0, yT + e); v(xL, 0, yB + e)
        case 0x2558: v(m.cx, yB - e, m.h); h(yT, m.cx - e, m.w); h(yB, m.cx - e, m.w) // ╘
        case 0x2559: v(xL, m.cy - e, m.h); v(xR, m.cy - e, m.h); h(m.cy, xL - e, m.w) // ╙
        case 0x255A:                                                           // ╚
            h(yB, xL - e, m.w); h(yT, xR - e, m.w)
            v(xL, yB - e, m.h); v(xR, yT - e, m.h)
        case 0x255B: v(m.cx, yB - e, m.h); h(yT, 0, m.cx + e); h(yB, 0, m.cx + e) // ╛
        case 0x255C: v(xL, m.cy - e, m.h); v(xR, m.cy - e, m.h); h(m.cy, 0, xR + e) // ╜
        case 0x255D:                                                           // ╝
            h(yB, 0, xR + e); h(yT, 0, xL + e)
            v(xR, yB - e, m.h); v(xL, yT - e, m.h)
        case 0x255E: v(m.cx, 0, m.h); h(yT, m.cx - e, m.w); h(yB, m.cx - e, m.w) // ╞
        case 0x255F: v(xL, 0, m.h); v(xR, 0, m.h); h(m.cy, xR - e, m.w)        // ╟
        case 0x2560:                                                           // ╠
            v(xL, 0, m.h); v(xR, 0, yB + e); v(xR, yT - e, m.h)
            h(yT, xR - e, m.w); h(yB, xR - e, m.w)
        case 0x2561: v(m.cx, 0, m.h); h(yT, 0, m.cx + e); h(yB, 0, m.cx + e)   // ╡
        case 0x2562: v(xL, 0, m.h); v(xR, 0, m.h); h(m.cy, 0, xL + e)          // ╢
        case 0x2563:                                                           // ╣
            v(xR, 0, m.h); v(xL, 0, yB + e); v(xL, yT - e, m.h)
            h(yT, 0, xL + e); h(yB, 0, xL + e)
        case 0x2564: h(yT, 0, m.w); h(yB, 0, m.w); v(m.cx, 0, yB + e)          // ╤
        case 0x2565: h(m.cy, 0, m.w); v(xL, 0, m.cy + e); v(xR, 0, m.cy + e)   // ╥
        case 0x2566:                                                           // ╦
            h(yT, 0, m.w); h(yB, 0, xL + e); h(yB, xR - e, m.w)
            v(xL, 0, yB + e); v(xR, 0, yB + e)
        case 0x2567: h(yT, 0, m.w); h(yB, 0, m.w); v(m.cx, yT - e, m.h)        // ╧
        case 0x2568: h(m.cy, 0, m.w); v(xL, m.cy - e, m.h); v(xR, m.cy - e, m.h) // ╨
        case 0x2569:                                                           // ╩
            h(yB, 0, m.w); h(yT, 0, xL + e); h(yT, xR - e, m.w)
            v(xL, yT - e, m.h); v(xR, yT - e, m.h)
        case 0x256A: v(m.cx, 0, m.h); h(yT, 0, m.w); h(yB, 0, m.w)             // ╪
        case 0x256B: h(m.cy, 0, m.w); v(xL, 0, m.h); v(xR, 0, m.h)             // ╫
        case 0x256C:                                                           // ╬
            h(yT, 0, xL + e); h(yT, xR - e, m.w)
            h(yB, 0, xL + e); h(yB, xR - e, m.w)
            v(xL, 0, yB + e); v(xL, yT - e, m.h)
            v(xR, 0, yB + e); v(xR, yT - e, m.h)
        default: break
        }
    }

    // MARK: Arcs and diagonals (antialiased strokes)

    private static func arc(_ scalar: UInt32, _ m: Metrics, _ ctx: CGContext) {
        let radius = min(m.cx, m.cy)
        let (start, end): (CGPoint, CGPoint)
        switch scalar {
        case 0x256D: (start, end) = (CGPoint(x: m.cx, y: 0), CGPoint(x: m.w, y: m.cy)) // ╭
        case 0x256E: (start, end) = (CGPoint(x: m.cx, y: 0), CGPoint(x: 0, y: m.cy))   // ╮
        case 0x256F: (start, end) = (CGPoint(x: m.cx, y: m.h), CGPoint(x: 0, y: m.cy)) // ╯
        case 0x2570: (start, end) = (CGPoint(x: m.cx, y: m.h), CGPoint(x: m.w, y: m.cy)) // ╰
        default: return
        }
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(m.light)
        ctx.move(to: start)
        ctx.addArc(
            tangent1End: CGPoint(x: m.cx, y: m.cy), tangent2End: end,
            radius: radius)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.setShouldAntialias(false)
    }

    private static func diagonal(_ scalar: UInt32, _ m: Metrics, _ ctx: CGContext) {
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(m.light)
        if scalar == 0x2571 || scalar == 0x2573 { // ╱ ╳
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: m.w, y: m.h))
        }
        if scalar == 0x2572 || scalar == 0x2573 { // ╲ ╳
            ctx.move(to: CGPoint(x: 0, y: m.h))
            ctx.addLine(to: CGPoint(x: m.w, y: 0))
        }
        ctx.strokePath()
        ctx.setShouldAntialias(false)
    }

    // MARK: Block elements (U+2580–259F)

    private static func blockElement(_ scalar: UInt32, _ m: Metrics, _ ctx: CGContext) {
        // All edges derive from the same rounded eighth-boundaries, so
        // complements (▀/▄, ▌/▐, quadrant pairs) tile with no gap or overlap.
        func lower(_ eighths: Int) -> CGRect {
            CGRect(x: 0, y: 0, width: m.w, height: (m.h * CGFloat(eighths) / 8).rounded())
        }
        func upper(_ eighths: Int) -> CGRect {
            let y = (m.h * CGFloat(8 - eighths) / 8).rounded()
            return CGRect(x: 0, y: y, width: m.w, height: m.h - y)
        }
        func left(_ eighths: Int) -> CGRect {
            CGRect(x: 0, y: 0, width: (m.w * CGFloat(eighths) / 8).rounded(), height: m.h)
        }
        func right(_ eighths: Int) -> CGRect {
            let x = (m.w * CGFloat(8 - eighths) / 8).rounded()
            return CGRect(x: x, y: 0, width: m.w - x, height: m.h)
        }
        let xm = (m.w / 2).rounded()
        let ym = (m.h / 2).rounded()
        let quadLL = CGRect(x: 0, y: 0, width: xm, height: ym)
        let quadLR = CGRect(x: xm, y: 0, width: m.w - xm, height: ym)
        let quadUL = CGRect(x: 0, y: ym, width: xm, height: m.h - ym)
        let quadUR = CGRect(x: xm, y: ym, width: m.w - xm, height: m.h - ym)

        switch scalar {
        case 0x2580: ctx.fill(upper(4))                                  // ▀
        case 0x2581...0x2588: ctx.fill(lower(Int(scalar) - 0x2580))      // ▁–█
        case 0x2589...0x258F: ctx.fill(left(0x2590 - Int(scalar)))       // ▉–▏
        case 0x2590: ctx.fill(right(4))                                  // ▐
        case 0x2591, 0x2592, 0x2593:                                     // ░▒▓
            // Shades as uniform coverage; the blend with the cell background
            // happens in the glyph shader exactly as antialiasing would.
            let shade: CGFloat = scalar == 0x2591 ? 0.25 : scalar == 0x2592 ? 0.5 : 0.75
            ctx.setFillColor(gray: shade, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: m.w, height: m.h))
        case 0x2594: ctx.fill(upper(1))                                  // ▔
        case 0x2595: ctx.fill(right(1))                                  // ▕
        case 0x2596: ctx.fill(quadLL)                                    // ▖
        case 0x2597: ctx.fill(quadLR)                                    // ▗
        case 0x2598: ctx.fill(quadUL)                                    // ▘
        case 0x2599: ctx.fill([quadUL, quadLL, quadLR])                  // ▙
        case 0x259A: ctx.fill([quadUL, quadLR])                          // ▚
        case 0x259B: ctx.fill([quadUL, quadUR, quadLL])                  // ▛
        case 0x259C: ctx.fill([quadUL, quadUR, quadLR])                  // ▜
        case 0x259D: ctx.fill(quadUR)                                    // ▝
        case 0x259E: ctx.fill([quadUR, quadLL])                          // ▞
        case 0x259F: ctx.fill([quadUR, quadLL, quadLR])                  // ▟
        default: break
        }
    }
}
