import Darwin
import Foundation

/// Sidebar/hover-card metadata probes. The cheap ones (cwd, process name)
/// are kernel calls safe to poll at 1 Hz; the git probe spawns a process
/// and runs async with a per-directory cache.
enum SessionInfo {
    /// Working directory of a process via proc_pidinfo. Nil for zombies
    /// or pids we can't inspect.
    nonisolated static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    nonisolated static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Just the directory name for tight spots like sidebar rows:
    /// "/Users/dmb/dev/kmono" → "kmono". Home stays "~".
    nonisolated static func displayName(path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// "~/dev/claude-app" form for display.
    nonisolated static func abbreviate(path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Current git branch by reading .git/HEAD directly — no subprocess, so
    /// it's safe to call synchronously (jump menu opening). Walks up from
    /// `directory` to the repo root and follows worktree/submodule
    /// "gitdir:" indirection. Detached HEAD yields a short hash.
    nonisolated static func gitBranch(near directory: String) -> String? {
        var dir = directory
        while true {
            let gitPath = dir + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                var headPath = gitPath + "/HEAD"
                if !isDirectory.boolValue {
                    guard let pointer = try? String(contentsOfFile: gitPath, encoding: .utf8),
                          pointer.hasPrefix("gitdir:") else { return nil }
                    var gitDir = pointer.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !gitDir.hasPrefix("/") { gitDir = dir + "/" + gitDir }
                    headPath = gitDir + "/HEAD"
                }
                guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
                else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") {
                    return String(trimmed.dropFirst("ref: refs/heads/".count))
                }
                return trimmed.isEmpty ? nil : String(trimmed.prefix(8))
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    struct GitStatus: Equatable, Sendable {
        var branch: String
        var dirtyCount: Int
    }

    /// Git branch + dirty count for a directory, async off the main thread.
    /// Results are cached briefly so hover jitter doesn't fork git storms.
    @MainActor
    static func gitStatus(
        in directory: String, completion: @escaping @MainActor (GitStatus?) -> Void
    ) {
        if let (stamp, status) = gitCache[directory],
           Date().timeIntervalSince(stamp) < 5 {
            completion(status)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = runGitStatus(in: directory)
            DispatchQueue.main.async {
                gitCache[directory] = (Date(), status)
                completion(status)
            }
        }
    }

    @MainActor private static var gitCache: [String: (Date, GitStatus?)] = [:]

    nonisolated private static func runGitStatus(in directory: String) -> GitStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", directory, "status", "--porcelain", "--branch", "--no-renames",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        // "## main...origin/main [ahead 1]" or "## HEAD (no branch)"
        guard let header = lines.popFirst(), header.hasPrefix("## ") else { return nil }
        var branch = String(header.dropFirst(3))
        if let dots = branch.range(of: "...") {
            branch = String(branch[..<dots.lowerBound])
        } else if let space = branch.firstIndex(of: " ") {
            branch = String(branch[..<space])
        }
        return GitStatus(branch: branch, dirtyCount: lines.count)
    }
}
