import XCTest
@testable import LidCodeKit

/// The deadline that turned "the app froze and I had to force-quit it" into "one
/// missed reading".
///
/// Both subprocesses LidCode spawns used to run `Process` + `readDataToEndOfFile()` +
/// `waitUntilExit()` with no timeout. `pmset -g` blocks indefinitely when `powerd` is
/// busy; a hung `ps` blocks the process watcher. Neither has a bound of its own, so the
/// bound has to come from here.
final class ShellCommandTest: XCTestCase {
    func testFastCommandReturnsOutput() {
        let output = ShellCommand.run("/bin/echo", ["hello"], timeoutSecond: 5)
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testMissingExecutableIsNilRatherThanACrash() {
        XCTAssertNil(ShellCommand.run("/nonexistent/binary", [], timeoutSecond: 1))
    }

    /// Output larger than the 64 KB pipe buffer. This is the case that deadlocks if the
    /// caller reads to EOF on its own thread while also waiting for exit: the child
    /// blocks in `write()` waiting for a reader, the parent blocks in `waitpid()`
    /// waiting for the child. Draining on a background queue is what avoids it.
    func testLargeOutputDoesNotDeadlock() {
        let output = ShellCommand.run(
            "/usr/bin/yes", [String(repeating: "x", count: 80)], timeoutSecond: 1)
        // `yes` never exits, so this is a timeout — the assertion that matters is that
        // it *returned* rather than wedging on a full pipe.
        XCTAssertNil(output)
    }

    /// The headline case: a command that would run for 30 seconds gives up in well
    /// under a second and hands back nil.
    func testSlowCommandTimesOut() {
        let start = Date()
        let output = ShellCommand.run("/bin/sleep", ["30"], timeoutSecond: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(output, "a command past its deadline has no answer, not a partial one")
        XCTAssertLessThan(elapsed, 1.5, "the deadline is the whole point")
    }

    /// A timeout must actually kill the child. Left alone, a 30-second `sleep` spawned
    /// every 10 seconds by the watcher would accumulate hundreds of live processes.
    func testTimedOutChildIsKilled() throws {
        let marker = "lidcode-timeout-\(UUID().uuidString)"
        _ = ShellCommand.run("/bin/sleep", ["30", marker], timeoutSecond: 0.3)

        // SIGTERM, then SIGKILL a quarter-second later, then the kernel has to reap it.
        // A second of slack keeps this from being a race on a loaded CI box.
        Thread.sleep(forTimeInterval: 1.0)

        let table = ShellCommand.run("/bin/ps", ["-Ao", "pid=,args="], timeoutSecond: 5) ?? ""
        let survivor = table
            .split(separator: "\n")
            .filter { $0.contains(marker) && !$0.contains("ps -Ao") }
        XCTAssertTrue(survivor.isEmpty, "timed-out children must not leak: \(survivor)")
    }

    /// Repeated timeouts must not accumulate threads or descriptors. If the drain
    /// closure leaked, this is where it would show up as the run slowing to a crawl.
    func testRepeatedTimeoutsStayBounded() {
        let start = Date()
        for _ in 0..<5 {
            XCTAssertNil(ShellCommand.run("/bin/sleep", ["10"], timeoutSecond: 0.2))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testExitCodeFailureStillReturnsWhateverWasWritten() {
        // `false` writes nothing and exits 1. The contract is "stdout, whatever it was",
        // not "nil on non-zero" — callers decide what an empty reading means.
        XCTAssertEqual(ShellCommand.run("/usr/bin/false", [], timeoutSecond: 5), "")
    }

    /// Regression for the `waitUntilExit`-on-concurrent-queue thread leak.
    ///
    /// The defect: `waitForExit` dispatched `process.waitUntilExit()` onto `readQueue`
    /// (a `.concurrent` libdispatch queue). When the caller timed out and returned, the
    /// dispatched block stayed blocked in `waitUntilExit()` forever, permanently holding
    /// a worker thread. libdispatch caps concurrent queues at 64 threads; once enough
    /// leaked waiters accumulated, the drain closure could no longer be scheduled and
    /// every subsequent `ShellCommand.run` timed out — the freeze the user reported.
    ///
    /// This test fires 20 guaranteed timeouts (sleep commands that far exceed the
    /// budget) and measures the thread count before and after. With the old code each
    /// timeout would park one thread permanently; 20 runs → 20 extra threads, a growth
    /// of 20+. The fixed code uses `terminationHandler` whose semaphore signal is
    /// instantaneous and never blocks a thread, so the count must not grow by more than
    /// a small constant tied to transient scheduler activity.
    func testRepeatedTimeoutsDoNotLeakWorkerThreads() throws {
        let pid = ProcessInfo.processInfo.processIdentifier

        func threadCount() -> Int {
            // `ps -M` prints one line per thread for the given pid. The header line is
            // always present, so the real count is lineCount - 1.
            let result = ShellCommand.run("/bin/ps", ["-M", "-p", "\(pid)"], timeoutSecond: 5) ?? ""
            let lines = result.split(separator: "\n", omittingEmptySubsequences: true)
            return max(0, lines.count - 1)
        }

        // Warm up the queue so start-up thread creation does not skew the baseline.
        for _ in 0..<3 {
            XCTAssertNil(ShellCommand.run("/bin/sleep", ["10"], timeoutSecond: 0.15))
        }
        Thread.sleep(forTimeInterval: 0.3)

        let before = threadCount()

        // 20 commands that each guarantee a timeout. With the old code, every one of
        // these would permanently park a worker thread in waitUntilExit().
        for _ in 0..<20 {
            XCTAssertNil(ShellCommand.run("/bin/sleep", ["10"], timeoutSecond: 0.15))
        }

        // Give the scheduler a moment to settle before counting.
        Thread.sleep(forTimeInterval: 0.5)

        let after = threadCount()
        let growth = after - before

        // Allow a generous slack of 8 threads for transient activity (drain closures in
        // flight, the ps command itself). A true leak of 20 threads is far outside this.
        XCTAssertLessThanOrEqual(
            growth, 8,
            "thread count grew by \(growth) after 20 timeouts — "
            + "before=\(before) after=\(after); "
            + "waitUntilExit() on a shared queue is likely back"
        )
    }
}
