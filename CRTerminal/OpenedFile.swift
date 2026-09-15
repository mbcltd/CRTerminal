import Foundation

/// What to do with a file Launch Services hands the app — dragged onto the
/// Dock icon, double-clicked, or chosen via Finder's "Open With". The
/// document types crterm claims (shell scripts, Unix executables, folders)
/// are declared in `CRTerminal-Info.plist`; this mirrors Terminal.app:
/// a folder opens a new shell there, an executable script runs in its own
/// session, and a script without the executable bit is refused with an
/// explanation rather than run through `sh` behind the user's back.
enum OpenedFile {
    enum Action: Equatable {
        /// A folder: open an interactive shell in it.
        case openShell(directory: String)
        /// An executable file: run it in a fresh session, in its own folder.
        case run(path: String)
        /// A regular file without execute permission.
        case notExecutable(path: String)
        case missing(path: String)
    }

    static func action(for url: URL, fileManager: FileManager = .default) -> Action {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing(path: path)
        }
        if isDirectory.boolValue { return .openShell(directory: path) }
        return fileManager.isExecutableFile(atPath: path)
            ? .run(path: path) : .notExecutable(path: path)
    }

    /// The command line the login shell runs for a script. Going through the
    /// user's login shell (rather than exec'ing the file directly, as
    /// Terminal.app does) means a Finder-launched script sees the PATH the
    /// user's profile sets up, not launchd's bare one — the classic "works in
    /// a terminal, fails when double-clicked" trap. `exec` then makes the
    /// script the session's process, so the sidebar tracks it directly.
    static func command(running path: String) -> String {
        "exec " + FileDrop.shellEscape(path)
    }

    static func displayName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Text printed in-surface when a command session's process exits,
    /// before the pane waits for a keypress. `resetAlternateScreen` restores
    /// the main screen if the script died inside a full-screen program (the
    /// switch is only emitted when needed: `?1049l` while already on the main
    /// screen would restore a stale saved cursor). `atLineStart` skips the
    /// line break when the script's last output already ended one, so the
    /// banner sits directly under it.
    static func completionBanner(
        status: Int32, resetAlternateScreen: Bool, atLineStart: Bool
    ) -> String {
        let esc = "\u{1B}"
        var text = ""
        if resetAlternateScreen { text += "\(esc)[?1049l" }
        // Show the cursor, drop attributes, start on a fresh line.
        text += "\(esc)[?25h\(esc)[0m"
        if !atLineStart { text += "\r\n" }
        text += "\(esc)[1m[Process completed: \(TerminalSession.exitDescription(status: status))]"
        text += "\(esc)[0m\r\nPress any key to close this session.\r\n"
        return text
    }
}
