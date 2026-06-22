import Foundation
import TerminalCore

/// The find bar's grep-style flag chips (match-case, whole-word, regex),
/// persisted in UserDefaults in the `AlertSettings` mold. A person-level
/// preference rather than a per-session one: the toggles you last left set
/// apply to every tab and window, and survive restarts. The find bar is
/// recreated on each ⌘F, so reading this store on open is what makes the
/// chips "sticky" across tabs.
@MainActor
final class SearchSettings {
    static let shared = SearchSettings()
    private let defaults: UserDefaults

    /// Injectable store so tests stay out of the real domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Match case (`Aa` chip).
    var caseSensitive: Bool {
        get { defaults.bool(forKey: "SearchMatchCase") }
        set { defaults.set(newValue, forKey: "SearchMatchCase") }
    }

    /// Whole-word boundaries (`\b` chip).
    var wholeWord: Bool {
        get { defaults.bool(forKey: "SearchWholeWord") }
        set { defaults.set(newValue, forKey: "SearchWholeWord") }
    }

    /// Regular-expression matching (`.*` chip).
    var regex: Bool {
        get { defaults.bool(forKey: "SearchRegex") }
        set { defaults.set(newValue, forKey: "SearchRegex") }
    }

    /// The chips as a `SearchOptions` for the core engine.
    var options: SearchOptions {
        SearchOptions(caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex)
    }
}
