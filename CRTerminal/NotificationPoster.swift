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

/// Delivers OSC 9 / OSC 777 terminal notifications and plain-BEL alerts
/// through Notification Center — but only when the terminal isn't
/// frontmost; a bell in the window you're looking at would just be noise.
/// Tapping a notification jumps to the session that posted it.
@MainActor
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPoster()
    private var authorizationRequested = false
    /// Last bell posted per session, for the burst debounce.
    private var lastBellPost: [UUID: Date] = [:]
    /// Posting talks to the real Notification Center (and requests
    /// authorization); the test host must never do that.
    private static let isUnderTest = NSClassFromString("XCTestCase") != nil

    /// Claims the center's delegate so taps can jump; call at launch.
    func activate() {
        guard !Self.isUnderTest else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// OSC 9 / 777: the application composed the message itself.
    func post(
        _ notification: TerminalNotification, windowIsKey: Bool,
        sessionID: UUID? = nil
    ) {
        guard AlertSettings.shared.notifications else { return }
        guard !windowIsKey || !NSApp.isActive else { return }
        deliver(
            title: notification.title.isEmpty ? "CRTerminal" : notification.title,
            body: notification.body, sessionID: sessionID)
    }

    /// Plain BEL: only when the whole app is in the background (in the
    /// foreground the sound + sidebar badge already cover it), and at
    /// most once per session per burst.
    func postBell(sessionID: UUID, title: String, body: String) {
        guard AlertSettings.shared.notifications else { return }
        guard !NSApp.isActive else { return }
        guard shouldPostBell(for: sessionID) else { return }
        deliver(title: title, body: body, sessionID: sessionID)
    }

    /// A bell burst posts once: 2s per-session debounce. Records the
    /// post time only when answering yes, so an ongoing burst stays
    /// quiet rather than re-arming on every ring.
    func shouldPostBell(for sessionID: UUID, at now: Date = Date()) -> Bool {
        if let last = lastBellPost[sessionID], now.timeIntervalSince(last) < 2 {
            return false
        }
        lastBellPost[sessionID] = now
        return true
    }

    private func deliver(title: String, body: String, sessionID: UUID?) {
        guard !Self.isUnderTest else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sessionID {
            content.userInfo = ["sessionID": sessionID.uuidString]
        }
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A notification was tapped: land on the session that posted it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = (response.notification.request.content
            .userInfo["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        if let sessionID {
            DispatchQueue.main.async {
                AppDelegate.shared?.focusSession(id: sessionID)
            }
        }
        completionHandler()
    }
}
