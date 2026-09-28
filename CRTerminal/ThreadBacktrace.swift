import Darwin
import Foundation
import MachO

@_silgen_name("swift_demangle")
private nonisolated func swiftDemangle(
    _ mangledName: UnsafePointer<CChar>?, _ mangledNameLength: Int,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<Int>?, _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

/// In-process stack sampling for the freeze watchdog: suspend a thread,
/// walk its frame-pointer chain, resume it. Apple's arm64 ABI keeps a frame
/// record in every frame, so no unwind tables are needed, and sampling our
/// own task needs no debugger entitlement (unlike `sample`, which a
/// hardened-runtime release build refuses).
nonisolated enum ThreadBacktrace {
    static let maxFrames = 128

    /// Code addresses carry a pointer-authentication signature in their
    /// high bits (system libraries are arm64e even in an arm64 process);
    /// user-space code lives far below 2^36.
    private static let addressMask: UInt = 0x0000_000F_FFFF_FFFF

    /// Return addresses of `thread`, innermost first; empty when the thread
    /// is gone or is the caller's own. Between suspend and resume nothing
    /// may allocate or take a lock — the suspended thread may hold the
    /// malloc or dyld lock, and we'd deadlock on it — so frames land in a
    /// buffer allocated up front and are copied out after resuming.
    static func capture(_ thread: thread_t) -> [UInt] {
        #if arch(arm64)
        guard thread != 0, thread != pthread_mach_thread_np(pthread_self()),
              let pthread = pthread_from_mach_thread_np(thread) else { return [] }
        let stackTop = UInt(bitPattern: pthread_get_stackaddr_np(pthread))
        let stackBottom = stackTop - UInt(pthread_get_stacksize_np(pthread))
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer { frames.deallocate() }
        var count = 0

        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64),
                                 $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            frames[0] = UInt(state.__pc) & addressMask
            frames[1] = UInt(state.__lr) & addressMask
            count = 2
            // Each frame record is {caller's record, return address}, and
            // records climb toward the stack top. Stop at anything outside
            // this thread's stack or not strictly ascending: a corrupt chain.
            var record = UInt(state.__fp)
            while count < maxFrames, record >= stackBottom,
                  record <= stackTop - 16, record & 0x7 == 0 {
                let words = UnsafePointer<UInt>(bitPattern: record)!
                let returnAddress = words[1] & addressMask
                guard returnAddress != 0 else { break }
                frames[count] = returnAddress
                count += 1
                guard words[0] > record else { break }
                record = words[0]
            }
        }
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: frames, count: count))
        #else
        return []
        #endif
    }

    /// One crash-report-style line per frame: index, image, address, the
    /// image's load address + offset (for `atos -l` against the dSYM, since
    /// release binaries are stripped), then the nearest exported symbol.
    static func symbolicate(_ addresses: [UInt]) -> [String] {
        addresses.enumerated().map { index, address in
            // A return address points past its call; look up the call
            // itself so a noreturn call ending a function names that function.
            let lookup = index == 0 ? address : address &- 1
            let number = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
            let hex = String(format: "0x%016lx", address)
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0,
                  let base = info.dli_fbase else {
                return "\(number)???  \(hex)"
            }
            let path = info.dli_fname.map { String(cString: $0) } ?? "???"
            let image = (path as NSString).lastPathComponent
            let loadAddress = UInt(bitPattern: base)
            var line = "\(number)\(image)"
                + String(repeating: " ", count: max(1, 28 - image.count))
                + "\(hex) " + String(format: "0x%lx + %lu", loadAddress, address - loadAddress)
            if let name = info.dli_sname, let start = info.dli_saddr {
                line += "  \(demangle(name)) + \(address - UInt(bitPattern: start))"
            }
            return line
        }
    }

    /// Swift symbols read back as source-level names; C symbols pass through.
    static func demangle(_ symbol: UnsafePointer<CChar>) -> String {
        guard let demangled = swiftDemangle(symbol, strlen(symbol), nil, nil, 0) else {
            return String(cString: symbol)
        }
        defer { free(demangled) }
        return String(cString: demangled)
    }

    /// LC_UUID of the main executable, to match a report to its dSYM.
    static var executableUUID: String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var command = UnsafeRawPointer(header)
            .advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_UUID {
                return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
