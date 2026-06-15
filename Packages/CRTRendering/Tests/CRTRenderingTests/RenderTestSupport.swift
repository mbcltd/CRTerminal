import CoreGraphics
import CoreText
import Foundation
@testable import CRTRendering

/// Shared CoreText setup for the rendering tests.
///
/// These tests exist under the shadow of the CoreText/fontd registration wedge
/// (see CLAUDE.md): once it trips, every `CTFontCreateWithName` blocks forever
/// at 0% CPU and the whole run hangs. We shrink the race window to nothing by
/// doing ALL fontd interaction exactly once, up front, before any renderer is
/// built. After that, creating a font for an already-resolved face is a cache
/// hit that never reaches fontd — so tests still get a *fresh* renderer each
/// (effect/animation state must not leak between them), just a safe one.
enum RenderTestSupport {
    /// Funnels every renderer/atlas helper through the one-time bootstrap.
    static func ready() { _ = bootstrap }

    private static let bootstrap: Void = {
        // Stop fontd auto-activation: with no automatic XPC round-trips there is
        // nothing left to race the in-process registration that wedged lookups.
        // A nil bundle identifier targets this (test-runner) process.
        CTFontManagerSetAutoActivationSetting(nil, .disabled)
        // Register the bundled faces via the in-process API (never URL-based).
        BundledFonts.register()
        // Pre-warm: force CoreText's lazy fontd connection and each face the
        // tests touch, once, serially, before anything else can.
        for name in [
            BundledFonts.geistMono, BundledFonts.departureMono,
            BundledFonts.c64, BundledFonts.symbolsNerdFont, "Menlo",
        ] {
            _ = CTFontCreateWithName(name as CFString, 12, nil)
        }
    }()

    static func menlo() -> TerminalRenderer? { renderer(face: "Menlo") }
    static func geistMono() -> TerminalRenderer? { renderer(face: BundledFonts.geistMono) }

    /// A fresh renderer for the given face, built only after the bootstrap has
    /// resolved that face — so the CTFontCreateWithName here can't wedge.
    static func renderer(face: String, scale: CGFloat = 1) -> TerminalRenderer? {
        ready()
        return TerminalRenderer(
            font: CTFontCreateWithName(face as CFString, 12, nil), scale: scale)
    }
}
