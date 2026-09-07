import Foundation

/// Every subprocess LidCode spawns, with a deadline attached.
///
/// This exists because of a freeze, not for tidiness. `PmsetReader` and
/// `ProcessWatcher` both used to run `Process` + `readDataToEndOfFile()` +
/// `waitUntilExit()` with no timeout, on the runtime's serial queue. `pmset -g` blocks
/// indefinitely when `powerd` is busy, and `/bin/ps -A` can stall behind a wedged
/// filesystem — and the moment either of them hangs, the runtime queue is stuck
/// forever. The main thread then deadlocks on its next `queue.sync`, which is the
/// reported symptom exactly: the menu bar icon is still drawn but nothing responds.
///
/// A hard deadline does not fix the architecture (see the snapshot cache in
/// `LidCodeRuntime`), but it turns "wedged forever" into "one missed reading", which is
/// a state the callers already know how to handle: they all treat empty output as
/// "unknown" rather than as a fact.
public enum ShellCommand {
    /// Runs a command and returns its stdout, or nil if it did not finish in time.
    ///
    /// - Parameter timeoutSecond: wall-clock budget. On expiry the child is sent
    ///   SIGTERM, then SIGKILL, and nil is returned.
    ///
    /// Both halves of the deadlock this replaces are avoided deliberately:
    ///
    /// 1. **stdout is drained on a background queue**, never on the calling thread.
    ///    Reading to EOF on the caller while also waiting for exit is the classic
    ///    pipe deadlock — a child that writes more than the 64 KB pipe buffer blocks
    ///    in `write()` waiting for a reader that is blocked in `waitpid()`. `ps -Ao`
    ///    on a busy Mac is well over 64 KB.
    /// 2. **The child is reaped via `terminationHandler`**, not `waitUntilExit()`.
    ///    Never call `waitUntilExit()` on a shared concurrent queue: it never returns
    ///    until the child dies, permanently consuming a worker thread even after the
    ///    caller gives up and moves on. Thirty such leaks fill libdispatch's 64-thread
    ///    cap, the drain closure can no longer be scheduled, every subsequent command
    ///    times out, and the app freezes until relaunch.
    ///
    /// The reader closure holds the only strong reference to its own buffer and always
    /// terminates when the pipe closes (which the kernel guarantees once the child is
    /// dead), so nothing leaks even on the timeout path.
    public static func run(
        _ path: String,
        _ arguments: [String],
        timeoutSecond: Double = 5
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr goes nowhere on purpose: it is never parsed, and wiring it to the same
        // pipe would let a chatty child's diagnostics land in the middle of the output
        // the caller is trying to parse.
        process.standardError = FileHandle.nullDevice

        let output = OutputBox()
        // Signalled by whichever finishes first, the drain or the deadline. `Process`
        // has a termination handler, but it fires before the pipe is necessarily
        // drained; the read loop ending *is* the "everything has arrived" signal.
        let finished = DispatchSemaphore(value: 0)
        // Signalled by terminationHandler — set before run() so a fast child cannot race.
        let exited = DispatchSemaphore(value: 0)

        // Must be assigned before process.run() to avoid a race where a very fast child
        // exits before the handler is installed.
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        readQueue.async {
            let handle = pipe.fileHandleForReading
            // `availableData` returns empty exactly once at EOF, which happens when the
            // child exits and its write end is closed — including when we kill it.
            while case let chunk = handle.availableData, !chunk.isEmpty {
                output.append(chunk)
            }
            // Release the read-end file descriptor promptly. Without this, ARC holds the
            // Pipe — and its two fds — until the process object is deallocated, which can
            // be much later. Closing here matches the actual end of use.
            try? handle.close()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeoutSecond) == .timedOut {
            // SIGTERM first so a well-behaved child can flush and exit; SIGKILL a beat
            // later for the ones that are wedged in the kernel and will never see it.
            // Both are needed: `pmset` hung on a busy `powerd` ignores SIGTERM.
            process.terminate()
            killQueue.asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            // Deliberately *not* waited on. The reader closure unblocks by itself when
            // the kernel closes the pipe, and blocking here to confirm that would
            // reintroduce the unbounded wait this whole function exists to remove.
            return nil
        }

        // Reap the child. It has already closed stdout (the drain loop ended), so this
        // cannot block for long — but the timeout is kept anyway so a zombie cannot pin
        // the caller. `DispatchSemaphore.wait(timeout:)` always returns; it cannot leak.
        _ = exited.wait(timeout: .now() + 1)
        return String(decoding: output.data, as: UTF8.self)
    }

    /// Concurrent on purpose: a blocked drain must never delay an unrelated command's
    /// drain, which a serial queue would do for the full length of the timeout.
    private static let readQueue = DispatchQueue(
        label: "com.lidcode.shell.read", qos: .utility, attributes: .concurrent)

    private static let killQueue = DispatchQueue(label: "com.lidcode.shell.kill", qos: .utility)
}

/// Lock-guarded accumulation buffer. The drain runs on another queue than the caller
/// that eventually reads it, and the semaphore only orders the *last* write — every
/// earlier append needs the lock to be visible.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
