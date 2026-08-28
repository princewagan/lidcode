import XCTest
@testable import LidCodeKit

/// These cases are all real `ps` rows observed on a normal Mac. Each one was a
/// false positive under substring matching, and each would have held the machine
/// awake indefinitely on an idle desk.
final class ProcessWatcherTest: XCTestCase {
    private func name(_ command: String) -> String {
        ProcessWatcher.executableName(from: command)
    }

    func testExecutableNameStripsPathAndArgument() {
        XCTAssertEqual(name("/Users/me/.local/bin/uv"), "uv")
        XCTAssertEqual(name("npm exec chrome-devtools-mcp@latest"), "npm")
        XCTAssertEqual(name("/Applications/CodexBar.app/Contents/MacOS/CodexBar"), "codexbar")
        XCTAssertEqual(name("python"), "python")
    }

    func testSystemDaemonNoLongerMatchesAnUnrelatedPattern() {
        // "appplaceholdersyncd" literally contains "rsync".
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/System/Library/CoreServices/appplaceholdersyncd"),
            pattern: "rsync"))
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/System/Library/Frameworks/Contacts.framework/Support/postersyncd"),
            pattern: "rsync"))
    }

    func testCameraAssistantDoesNotMatchUv() {
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name(".../UVCAssistant.systemextension/Contents/MacOS/UVCAssistant"),
            pattern: "uv"))
    }

    /// An always-running privileged helper must not read as "a Docker build".
    func testDockerHelperDaemonDoesNotMatchDocker() {
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/Library/PrivilegedHelperTools/com.docker.vmnetd"),
            pattern: "docker"))
    }

    /// A menu-bar app that is open all day must not read as an agent run.
    func testMenuBarAppDoesNotMatchAgentPattern() {
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/Applications/CodexBar.app/Contents/MacOS/CodexBar"),
            pattern: "codex"))
    }

    func testGenuineMatchStillWorks() {
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("/opt/homebrew/bin/claude"), pattern: "claude"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("npm exec tsx server.ts"), pattern: "npm"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("/Users/me/.local/bin/uv"), pattern: "uv"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("docker"), pattern: "docker"))
    }

    /// The one loosening worth keeping: versioned interpreter names.
    func testVersionSuffixStillMatches() {
        XCTAssertTrue(ProcessWatcher.matches(executableName: "python3", pattern: "python"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: "python3.13", pattern: "python"))
        XCTAssertFalse(ProcessWatcher.matches(executableName: "pythonista", pattern: "python"))
    }

    /// Guards against a default list that quietly reintroduces an always-on daemon.
    func testDefaultPatternExcludesServerShapedTool() {
        let pattern = Set(Setting.default.watchPattern)
        for banned in ["ollama", "com.docker.backend", "colima", "lm-studio", "vite"] {
            XCTAssertFalse(pattern.contains(banned),
                           "\(banned) runs continuously — watching it by name holds the Mac awake forever")
        }
    }

    /// The narrowed default (plan step 1.2 / BUG 5) must contain exactly the six
    /// agent-shaped binaries and nothing more.
    func testDefaultPatternIsNarrowedToAgentBinaries() {
        let pattern = Setting.default.watchPattern
        let expected = ["claude", "codex", "cursor-agent", "aider", "xcodebuild", "swift-frontend"]
        XCTAssertEqual(Set(pattern), Set(expected),
                       "default watchPattern must contain only agent-shaped binaries (no npm, cargo, rsync etc.)")
        XCTAssertEqual(pattern.count, expected.count, "count must match — no duplicates or extras")
    }

    /// Build tools and package managers removed in BUG 5 fix must not appear in the default.
    func testDefaultPatternExcludesBuildToolsRemovedInBug5() {
        let pattern = Set(Setting.default.watchPattern)
        for removed in ["cargo", "rustc", "make", "ninja", "gradle", "npm", "pnpm", "yarn",
                        "tsc", "esbuild", "python", "pytest", "uv", "poetry",
                        "docker", "ffmpeg", "rsync", "pandoc"] {
            XCTAssertFalse(pattern.contains(removed),
                           "\(removed) was removed in BUG 5 — it is not an agent binary and idles indefinitely")
        }
    }
}
