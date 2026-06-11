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
    private let ioQueue = DispatchQueue(label: "crterminal.pty.io", qos: .userInteractive)
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
    private let exited = OSAllocatedUnfairLock(initialState: false)

    /// Called on the IO queue with each chunk read from the PTY.
    var onData: ((Data) -> Void)?
    /// Called once, on the IO queue, when the child exits.
    var onExit: ((Int32) -> Void)?

    enum Failure: Error {
        case openpt(Int32)
        case spawn(Int32)
    }

    init(columns: Int, rows: Int) throws {
        // Master/slave pair via plain POSIX (no libutil dependency).
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw Failure.openpt(errno) }
        grantpt(master)
        unlockpt(master)
        let slavePath = String(cString: ptsname(master))

        var size = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, Self.TIOCSWINSZ, &size)

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

        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
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

        // Non-blocking source-driven reads.
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        exitSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: ioQueue)

        readSource.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        exitSource.setEventHandler { [weak self] in
            self?.handleExit()
        }
        readSource.resume()
        exitSource.resume()
    }

    deinit {
        readSource.cancel()
        exitSource.cancel()
        close(masterFD)
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
        _ = ioctl(masterFD, Self.TIOCSWINSZ, &size)
    }

    func terminate() {
        kill(processID, SIGHUP)
    }

    private func readAvailable() {
        // Bounded per wakeup; the kernel TTY buffer provides backpressure.
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        let count = read(masterFD, &buffer, buffer.count)
        if count > 0 {
            onData?(Data(buffer[0..<count]))
        } else if count == 0 || (count < 0 && errno == EIO) {
            handleExit() // EOF/EIO: slave side gone
        }
    }

    private func handleExit() {
        let alreadyExited = exited.withLock { state in
            defer { state = true }
            return state
        }
        guard !alreadyExited else { return }
        readSource.cancel()
        exitSource.cancel()
        var status: Int32 = 0
        waitpid(processID, &status, WNOHANG)
        onExit?(status)
    }
}
