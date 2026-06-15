import Darwin
import Foundation
import os

/// Swift marks fork() unavailable ("use posix_spawn"), but posix_spawn cannot
/// acquire a controlling terminal (there is no TIOCSCTTY file action), which a
/// terminal emulator strictly requires — bind the libc symbol directly.
@_silgen_name("fork") private nonisolated func sysFork() -> pid_t

/// Owns the PTY master fd and the shell process. Reads are delivered on a
/// dedicated serial queue; see ARCHITECTURE.md "PTY and process management".
/// Mutable state is confined to the IO queue or behind locks.
nonisolated final class PTYSession: @unchecked Sendable {
    /// _IOW('t', 103, struct winsize) — the importer can't expand the macro.
    private static let TIOCSWINSZ: UInt = 0x8008_7467
    /// _IO('t', 97) — acquire the tty as the controlling terminal.
    private static let TIOCSCTTY: UInt = 0x2000_7461

    let processID: pid_t
    private let masterFD: Int32
    /// Kept open for winsize ioctls: on macOS TIOCSWINSZ is ENOTTY on the
    /// master fd and must target the slave. Closed on child exit to unblock
    /// the reader's poll with HUP.
    private let slaveFD: Int32
    private let ioQueue = DispatchQueue(label: "crterminal.pty.io", qos: .userInteractive)
    /// Dedicated reader thread: blocking poll + drain beats a dispatch
    /// source by ~100k queue wakeups on a 100 MB firehose.
    private var readerThread: Thread?
    private let exitSource: DispatchSourceProcess
    private let exited = OSAllocatedUnfairLock(initialState: false)

    /// Called on the reader thread with each batch read from the PTY.
    var onData: (([UInt8]) -> Void)?
    /// Called once when the child exits (reader thread or IO queue).
    var onExit: ((Int32) -> Void)?

    enum Failure: Error {
        case openpt(Int32)
        case spawn(Int32)
    }

    init(columns: Int, rows: Int, shell: String? = nil,
         workingDirectory: String? = nil) throws {
        // Master/slave pair via plain POSIX (no libutil dependency).
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw Failure.openpt(errno) }
        grantpt(master)
        unlockpt(master)
        let slavePath = String(cString: ptsname(master))
        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw Failure.openpt(errno)
        }

        var size = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, Self.TIOCSWINSZ, &size)

        // Spawn the login shell login_tty-style: fork, setsid, then claim the
        // slave with TIOCSCTTY. posix_spawn cannot do this — there is no file
        // action for the ioctl, and on macOS merely opening a tty does NOT
        // acquire it as controlling terminal, so the POSIX_SPAWN_SETSID +
        // open-slave-as-fd-0 approach left the shell with no ctty (TPGID 0):
        // the line discipline ate ^C/^Z but had no foreground process group
        // to signal, and job control was silently broken.
        let shellPath = shell
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let loginArg0 = "-" + (shellPath as NSString).lastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "crterm"
        environment.removeValue(forKey: "TERM_PROGRAM_VERSION")
        // Auto-load shell integration (zsh) so command history / prompt marks
        // work without the user editing their dotfiles.
        ShellIntegration.install(into: &environment, shellPath: shellPath)

        // Everything the child touches is prepared before fork: between fork
        // and execve only async-signal-safe calls are allowed (no Swift
        // allocation — another thread may hold the malloc lock).
        let shellC = strdup(shellPath)
        defer { free(shellC) }
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: 2)
        argv[0] = strdup(loginArg0)
        argv[1] = nil
        defer {
            free(argv[0])
            argv.deallocate()
        }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: environment.count + 1)
        for (index, pair) in environment.enumerated() {
            envp[index] = strdup("\(pair.key)=\(pair.value)")
        }
        envp[environment.count] = nil
        defer {
            for index in 0..<environment.count { free(envp[index]) }
            envp.deallocate()
        }
        // Start the shell where the profile says (the app's own cwd is
        // "/" when launched from Finder — useless to inherit).
        let cwdC: UnsafeMutablePointer<CChar>? = workingDirectory.flatMap { strdup($0) }
        defer { free(cwdC) }

        let pid = sysFork()
        guard pid >= 0 else {
            let error = errno
            close(master)
            close(slave)
            throw Failure.spawn(error)
        }
        if pid == 0 {
            // Child. Become session leader and take the slave as the
            // controlling terminal, then wire it to stdio.
            if setsid() < 0 { _exit(126) }
            if ioctl(slave, Self.TIOCSCTTY, 0) != 0 { _exit(126) }
            dup2(slave, 0)
            dup2(slave, 1)
            dup2(slave, 2)
            // Undo the app's signal state: exec resets handled signals but
            // ignored dispositions (e.g. SIGPIPE) and the mask are inherited.
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            sigprocmask(SIG_SETMASK, &noSignals, nil)
            for sig in 1..<Int32(NSIG) where sig != SIGKILL && sig != SIGSTOP {
                signal(sig, SIG_DFL)
            }
            if let cwdC { chdir(cwdC) }
            // Keep the app's fds out of the shell (what CLOEXEC_DEFAULT did
            // under posix_spawn). F_SETFD is safe on guarded fds; close isn't
            // (EXC_GUARD).
            let fdLimit = Int32(min(max(sysconf(_SC_OPEN_MAX), 256), 65536))
            for fd in 3..<fdLimit {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
            execve(shellC, argv, envp)
            _exit(127)
        }

        processID = pid
        masterFD = master
        slaveFD = slave

        // Non-blocking reads (the reader thread blocks in poll instead).
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        exitSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: ioQueue)
        exitSource.setEventHandler { [weak self] in
            self?.handleExit()
        }
        exitSource.resume()

        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "crterminal.pty.read"
        thread.qualityOfService = .userInteractive
        thread.start()
        readerThread = thread
    }

    deinit {
        exitSource.cancel()
        close(masterFD)
        let slaveAlreadyClosed = exited.withLock { $0 }
        if !slaveAlreadyClosed {
            close(slaveFD)
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        ioQueue.async { [masterFD] in
            var remaining = bytes[...]
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes {
                    write(masterFD, $0.baseAddress, $0.count)
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                } else if errno == EAGAIN {
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slaveFD, Self.TIOCSWINSZ, &size)
    }

    func terminate() {
        kill(processID, SIGHUP)
    }

    /// Foreground process group of the PTY (what's currently "running"):
    /// equals the shell's pid at an idle prompt. -1 after exit.
    var foregroundProcessGroup: pid_t {
        guard !exited.withLock({ $0 }) else { return -1 }
        return tcgetpgrp(masterFD)
    }

    /// The kernel hands PTY data out ~1 KiB at a time (≈100k reads for a
    /// 100 MB cat). The reader thread blocks in poll, then drains to EAGAIN,
    /// delivering ~256 KiB batches — syscall-bound, no queue wakeups, with
    /// the kernel TTY buffer applying backpressure to the writer.
    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var batch: [UInt8] = []
        let batchLimit = 256 * 1024
        while true {
            var fds = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            batch.removeAll(keepingCapacity: true)
            var sawEOF = false
            while batch.count < batchLimit {
                let count = read(masterFD, &buffer, buffer.count)
                if count > 0 {
                    batch.append(contentsOf: buffer[0..<count])
                } else if count == 0 || (count < 0 && errno == EIO) {
                    sawEOF = true
                    break
                } else {
                    break // EAGAIN: drained for now
                }
            }
            if !batch.isEmpty {
                onData?(batch)
            }
            if sawEOF || fds.revents & Int16(POLLHUP | POLLNVAL | POLLERR) != 0 {
                if batch.isEmpty || sawEOF {
                    handleExit()
                    return
                }
            }
        }
    }

    private func handleExit() {
        let alreadyExited = exited.withLock { state in
            defer { state = true }
            return state
        }
        guard !alreadyExited else { return }
        exitSource.cancel()
        // Last slave holder: closing flips the reader's poll to HUP/EOF so
        // it drains any final buffered output and exits.
        close(slaveFD)
        var status: Int32 = 0
        waitpid(processID, &status, WNOHANG)
        onExit?(status)
    }
}
