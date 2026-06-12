import Foundation

/// Global alert behavior: which surfaces a bell reaches. UserDefaults-
/// backed singleton in the ProfileStore mold — writes broadcast via
/// onChange so open windows re-apply live. Global rather than
/// per-profile: "where do alerts go" is a person-level preference.
@MainActor
final class AlertSettings {
    static let shared = AlertSettings()
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    /// Injectable store so tests stay out of the real domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// System beep on every bell.
    var bellSound: Bool {
        get { bool("BellSound", default: true) }
        set { set(newValue, for: "BellSound") }
    }

    /// Phosphor flash on the ringing pane — also in the focused tab.
    var visualBell: Bool {
        get { bool("VisualBell", default: true) }
        set { set(newValue, for: "VisualBell") }
    }

    /// Amber dot on unwatched sessions' sidebar rows.
    var sidebarBadges: Bool {
        get { bool("SidebarBellBadges", default: true) }
        set { set(newValue, for: "SidebarBellBadges") }
    }

    /// Unattended-session count on the Dock icon.
    var dockBadge: Bool {
        get { bool("DockBadge", default: true) }
        set { set(newValue, for: "DockBadge") }
    }

    /// One Dock bounce when a bell arrives while the app is inactive.
    var dockBounce: Bool {
        get { bool("DockBounceOnBell", default: false) }
        set { set(newValue, for: "DockBounceOnBell") }
    }

    /// Notification Center posts (BEL and OSC 9/777) while in background.
    var notifications: Bool {
        get { bool("BellNotifications", default: true) }
        set { set(newValue, for: "BellNotifications") }
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func set(_ value: Bool, for key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
