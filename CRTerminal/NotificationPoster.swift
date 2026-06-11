import AppKit
import CRTRendering
import TerminalCore
import UserNotifications

/// All known presets: the launch set plus user JSON documents in
/// Application Support/CRTerminal/Presets.
@MainActor
enum PresetCatalog {
    static let userDirectory: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("CRTerminal/Presets", isDirectory: true)

    static let all: [CRTPreset] = {
        var presets = CRTPresetLibrary.builtIn
        if let dir = userDirectory {
            let user = CRTPresetLibrary.userPresets(in: dir)
                .filter { user in !presets.contains { $0.name == user.name } }
            presets.append(contentsOf: user)
        }
        return presets
    }()
}

/// Delivers OSC 9 / OSC 777 terminal notifications through Notification
/// Center — but only when the terminal isn't frontmost; a bell in the
/// window you're looking at would just be noise.
@MainActor
final class NotificationPoster {
    static let shared = NotificationPoster()
    private var authorizationRequested = false

    func post(_ notification: TerminalNotification, windowIsKey: Bool) {
        guard !windowIsKey || !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? "CRTerminal" : notification.title
        content.body = notification.body
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
