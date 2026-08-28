import Foundation

/// Read-only `pmset -g`, shared by `lidcode doctor` and the live health panel so the
/// two can never disagree about whether the Mac is allowed to sleep.
///
/// Nothing here writes. Every state change goes through the root helper.
public enum PmsetReader {
    /// Two seconds is generous for a command that normally answers in single-digit
    /// milliseconds, and short enough that a wedged `powerd` costs one health sweep
    /// rather than the whole app. See `ShellCommand` for why the deadline exists.
    public static let timeoutSecond: Double = 2

    public static func output() -> String {
        ShellCommand.run("/usr/bin/pmset", ["-g"], timeoutSecond: timeoutSecond) ?? ""
    }

    /// The key `pmset -g` actually prints, and the one it used to be assumed to print.
    ///
    /// The real output on macOS 14+ is `SleepDisabled` under "System-wide power
    /// settings"; `disablesleep` is the name you *write* (`pmset -a disablesleep 1`)
    /// and it is what older releases echoed back. Matching only the write spelling is
    /// the bug this list fixes — see `isDisableSleepOn`.
    static let disableSleepKey = ["sleepdisabled", "disablesleep"]

    /// `pmset -g` omits the row entirely when the value is 0, so absent means normal
    /// sleep — it is not an inconclusive reading.
    ///
    /// This returned `false` unconditionally for the entire life of the app. It looked
    /// for a row *containing* `"disablesleep"`, but the row macOS prints is
    /// `" SleepDisabled\t\t0"`, which lowercases to `"sleepdisabled"` — a different
    /// string. The visible symptom was the health panel's Sleep policy row stuck on
    /// "closed-lid on but disablesleep is 0" (red) for every closed-lid session, since
    /// `HealthProbe` only reaches that arm when the reading disagrees with reality.
    ///
    /// Two things are load-bearing in the matching:
    ///
    /// - The key is compared against the row's **first** whitespace-separated token,
    ///   not searched for anywhere in the line. `pmset -g` also prints
    ///   `sleep 1 (sleep prevented by caffeinate, powerd, ...)`, and a substring search
    ///   for a key inside that parenthetical is a coin flip waiting to happen.
    /// - The value is the row's **last** token compared to `"1"`, not `hasSuffix("1")`.
    ///   A suffix test says yes to `11`, and to any row that happens to end in a 1.
    public static func isDisableSleepOn(_ text: String = output()) -> Bool {
        for row in text.split(separator: "\n") {
            let field = row.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // A key with no value is a section header, not a setting.
            guard let key = field.first, field.count >= 2 else { continue }
            guard disableSleepKey.contains(key.lowercased()) else { continue }
            return field[field.count - 1] == "1"
        }
        return false
    }

    /// macOS names every process holding a sleep assertion on the `sleep` row. Useful
    /// for the common confusion of "LidCode released, so why is my Mac still awake?" —
    /// usually a stray `caffeinate` from three deploys ago.
    public static func assertionHolder(_ text: String = output()) -> String {
        for row in text.split(separator: "\n") where row.contains("sleep prevented by") {
            guard let open = row.firstIndex(of: "("), let close = row.lastIndex(of: ")") else { continue }
            return String(row[row.index(after: open)..<close])
                .replacingOccurrences(of: "sleep prevented by ", with: "")
        }
        return ""
    }
}
