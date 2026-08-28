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
}
