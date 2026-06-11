import Darwin
import Foundation
import os

/// Owns the PTY master fd and the shell process. Reads are delivered on a
/// dedicated serial queue; see ARCHITECTURE.md "PTY and process management".
/// Mutable state is confined to the IO queue or behind locks.
nonisolated final class PTYSession: @unchecked Sendable {
    /// _IOW('t', 103, struct winsize) — the importer can't expand the macro.
    private static let TIOCSWINSZ: UInt = 0x8008_7467

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

    init(columns: Int, rows: Int, shell: String? = nil) throws {
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

        // Spawn the login shell. POSIX_SPAWN_SETSID + opening the slave as fd
        // 0 makes it the controlling terminal (first tty open by the session
        // leader); CLOEXEC_DEFAULT keeps our fds out of the child.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setflags(&attr, Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        let shellPath = shell
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let loginArg0 = "-" + (shellPath as NSString).lastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "CRTerminal"
        environment.removeValue(forKey: "TERM_PROGRAM_VERSION")

        let argv = [strdup(loginArg0), nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid = pid_t(0)
        let result = posix_spawn(&pid, shellPath, &actions, &attr, argv, envp)
        guard result == 0 else {
            close(master)
            throw Failure.spawn(result)
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
