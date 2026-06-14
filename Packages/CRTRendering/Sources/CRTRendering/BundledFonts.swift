import CoreGraphics
import CoreText
import Foundation

/// Monospace fonts shipped with the app — SIL OFL 1.1 (Geist/Departure)
/// and CC0 public domain (C64); license texts sit beside the files in
/// Fonts/. Registered with process scope: usable in-app without
/// installing anything on the user's system.
public enum BundledFonts {
    /// PostScript names, usable directly with NSFont/CTFont.
    public static let geistMono = "GeistMono-Regular"
    public static let departureMono = "DepartureMono-Regular"
    /// The Commodore 64 PETSCII character set (CC0 public domain) — the
    /// Commodore 1702 preset wears it. Mixed-case, monospace.
    public static let c64 = "C64-Regular"
    /// Family names, for font pickers (process-registered fonts don't
    /// always surface in NSFontManager's lists).
    public static let families = ["Geist Mono", "Departure Mono", "C64"]

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
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "otf", subdirectory: "Fonts")
        else { return }
        for url in urls {
            guard let provider = CGDataProvider(url: url as CFURL),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }()
}
