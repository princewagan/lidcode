import Foundation

// MARK: - Git Branch Reader

/// Reads the current git branch for a given working directory.
///
/// ## Caching strategy
///
/// `.git/HEAD` is cheap to read (single line, no subprocess), but reading it
/// for every tab on every 5-second poll would still touch the filesystem
/// 40+ times per poll. We cache per-cwd with a 30-second TTL.
///
/// 30s is generous enough that a branch switch is reflected within a typical
/// interaction cycle (you switch branches, come back to the phone, it shows
/// the new branch within 30s). The tradeoff is negligible — branch switches
/// while watching the phone are rare.
///
/// The cache is an actor so concurrent reads from multiple dispatch queues
/// don't race on the dictionary.
///
/// ## Edge cases handled
///
/// - `.git` is a FILE (git worktrees): parse `gitdir: <path>` and follow it.
/// - Detached HEAD (SHA instead of branch ref): return nil.
/// - Missing `.git`: return nil.
/// - Unreadable file: return nil (never throw; treat as "no branch").
///
/// ## What we NEVER do
///
/// - Write to `.git` or any git path.
/// - Invoke `git` as a subprocess (would be slow and require PATH setup).
/// - Read anything outside of `<cwd>/.git/HEAD` (and the gitdir it points to).

public final class GitBranchReader: @unchecked Sendable {

    // MARK: - Cache entry

    private struct CacheEntry {
        let branch: String?
        let expiresAt: Date
    }

    // MARK: - State

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval

    public static let shared = GitBranchReader(ttl: 30)

    public init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    // MARK: - Public API

    /// Returns the current branch name for the given absolute directory path,
    /// or nil if the directory is not a git repo or HEAD is detached.
    ///
    /// Thread-safe. Results are cached per-cwd for `ttl` seconds.
    public func branch(for cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }

        let now = Date()

        lock.lock()
        if let entry = cache[cwd], entry.expiresAt > now {
            let cached = entry.branch
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Read outside the lock — file I/O can block and we don't want to hold
        // the lock while doing it. Two threads may both read for the same cwd;
        // that's fine — last writer wins in the cache update below.
        let branch = readBranch(cwd: cwd)

        lock.lock()
        cache[cwd] = CacheEntry(branch: branch, expiresAt: now.addingTimeInterval(ttl))
        lock.unlock()

        return branch
    }

    /// Force-evict the cache entry for a specific cwd.
    /// Used by tests to ensure fresh reads.
    public func invalidate(cwd: String) {
        lock.lock()
        cache.removeValue(forKey: cwd)
        lock.unlock()
    }

    /// Evict all entries. Used by tests.
    public func invalidateAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - Core logic

    /// Read the git branch for `cwd` from disk. Never throws; returns nil on any failure.
    private func readBranch(cwd: String) -> String? {
        let gitPath = (cwd as NSString).appendingPathComponent(".git")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
        guard exists else { return nil }

        let headPath: String
        if isDir.boolValue {
            // Normal repository: .git is a directory
            headPath = (gitPath as NSString).appendingPathComponent("HEAD")
        } else {
            // Worktree: .git is a FILE containing "gitdir: <absolute-or-relative-path>"
            guard let gitFileContent = try? String(contentsOfFile: gitPath, encoding: .utf8) else {
                return nil
            }
            let trimmed = gitFileContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("gitdir: ") else { return nil }
            var gitdirPath = String(trimmed.dropFirst("gitdir: ".count))
            // gitdir may be relative (common) or absolute
            if !gitdirPath.hasPrefix("/") {
                gitdirPath = (cwd as NSString).appendingPathComponent(gitdirPath)
            }
            // Normalize (resolve ..)
            gitdirPath = (gitdirPath as NSString).standardizingPath
            headPath = (gitdirPath as NSString).appendingPathComponent("HEAD")
        }

        return parseHEAD(at: headPath)
    }

    /// Parse a HEAD file and return the branch name, or nil for detached HEAD.
    private func parseHEAD(at path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let line = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Attached HEAD: "ref: refs/heads/<branch>"
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            let branch = String(line.dropFirst(prefix.count))
            return branch.isEmpty ? nil : branch
        }

        // Detached HEAD: a raw SHA-1 (40 hex chars) or short SHA.
        // We return nil — no branch name to display.
        return nil
    }
}
