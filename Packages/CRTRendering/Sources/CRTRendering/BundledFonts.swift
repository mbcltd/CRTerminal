import CoreGraphics
import CoreText
import Foundation

/// Monospace fonts shipped with the app — SIL OFL 1.1 (Geist/Departure),
/// CC0 public domain (C64), and MIT (Symbols Nerd Font); license texts
/// sit beside the files in Fonts/. Registered with process scope: usable
/// in-app without installing anything on the user's system.
public enum BundledFonts {
    /// PostScript names, usable directly with NSFont/CTFont.
    public static let geistMono = "GeistMono-Regular"
    public static let departureMono = "DepartureMono-Regular"
    /// The Commodore 64 PETSCII character set (CC0 public domain) — the
    /// Commodore 1702 preset wears it. Mixed-case, monospace.
    public static let c64 = "C64-Regular"
    /// The classic chunky 8-bit arcade face (SIL OFL) — the "RPG"
    /// theme wears it for that JRPG dialogue-box look. Monospace, but with
    /// sparse coverage (basic Latin + common punctuation); anything it
    /// lacks falls back through GlyphAtlas like any other face.
    public static let pressStart2P = "PressStart2P-Regular"
    /// Symbols-only Nerd Font (MIT): the icon glyphs Powerline, Nerd Fonts
    /// and friends park in the Unicode private-use areas. Not a user-facing
    /// typeface — GlyphAtlas pulls it in as a fallback layer for PUA scalars
    /// the primary font lacks (macOS ships no system fallback there).
    public static let symbolsNerdFont = "SymbolsNFM"
    /// Family names, for font pickers (process-registered fonts don't
    /// always surface in NSFontManager's lists). The symbols font is
    /// deliberately absent — it's a fallback layer, not a typeface choice.
    public static let families = ["Geist Mono", "Departure Mono", "C64", "Press Start 2P"]

    /// Registers exactly once per process, however many threads call it.
    /// Registration is graphics-font based — parsed from the file data
    /// and registered in-process — because it must not talk to fontd:
    /// URL registration is an XPC transaction, and racing it against the
    /// process's first font lookups (exactly what parallel tests do)
    /// wedged the font-registry connection, hanging every lookup forever.
    public static func register() {
        _ = registration
    }

    private static let registration: Void = {
        let urls = ["otf", "ttf"].flatMap {
            Bundle.module.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? []
        }
        for url in urls {
            guard let provider = CGDataProvider(url: url as CFURL),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }()
}
