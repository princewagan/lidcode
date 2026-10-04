import Foundation
import Darwin
import LidCodeKit

let cliVersion = LidCodeVersion.current

func out(_ text: String) { print(text) }
func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("lidcode: \(text)\n".utf8))
    exit(1)
}

/// Accepts `90`, `30m`, `3h`, `2h30m`.
func parseSecond(_ text: String) -> Int? {
    if let plain = Int(text) { return plain }
    var total = 0
    var digit = ""
    for character in text.lowercased() {
        if character.isNumber {
            digit.append(character)
            continue
        }
        guard let value = Int(digit) else { return nil }
        switch character {
        case "s": total += value
        case "m": total += value * 60
        case "h": total += value * 3600
        default: return nil
        }
        digit = ""
    }
    guard digit.isEmpty else { return nil }
    return total > 0 ? total : nil
}

func flagValue(_ name: String, in argument: [String]) -> String? {
    guard let index = argument.firstIndex(of: name), index + 1 < argument.count else { return nil }
    return argument[index + 1]
}

// MARK: - Talking to the app

/// `health` is the one request the app answers slowly on purpose: it re-runs the whole
/// sweep, including the network half, before replying. The default 5s read timeout is
/// tuned for the instant commands and would give up on a cold DNS cache mid-sweep, so
/// this one connection gets a window wider than the probe's own worst case.
func send(_ request: AppRequest, timeoutSecond: Int = 5) -> AppResponse {
    let client = LineSocketClient(path: LidCodePath.appSocket.path)
    do {
        try client.connect(timeoutSecond: timeoutSecond)
        return try client.roundTrip(request, expecting: AppResponse.self)
    } catch {
        fail(LidCodeError.appNotRunning.localizedDescription)
    }
}

func report(_ response: AppResponse) {
    switch response {
    case .ok(let message):      out(message)
    case .failed(let message):  fail(message)
    case .token(let token):     out(token)
    case .text(let line):       line.forEach(out)
    case .snapshot(let snap):   printSnapshot(snap)
    case .log(let entry):       entry.forEach { printEntry($0) }
    }
}

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func printSnapshot(_ snap: RuntimeSnapshot) {
    out("Mode:      \(snap.isAwakeHeld ? "Awake On" : "Awake Off") (\(snap.mode.rawValue))")
    out("Assertion: \(snap.isAssertionActive ? "active" : "inactive")")
    out("Clamshell: \(snap.isClamshellActive ? "on" : "off")")
    out("Battery:   \(snap.battery.display)")
    out("Thermal:   \(snap.thermal.level.display)")
    if snap.isAwakeHeld {
        out("Runtime:   \(snap.runtimeSecond / 60)m \(snap.runtimeSecond % 60)s")
    }
    if let expiresAt = snap.expiresAt {
        out("Expires:   \(stamp.string(from: expiresAt))")
    }
    if snap.activeLease.isEmpty {
        out("Holding:   nothing tracked")
    } else {
        out("Holding:   \(snap.activeLease.joined(separator: ", "))")
    }
    if let reason = snap.lastStopReason, !snap.isAwakeHeld {
        out("Last stop: \(reason.summary)")
    }
}

func printEntry(_ entry: LogEntry) {
    var line = "\(stamp.string(from: entry.at))  \(entry.kind.rawValue)  \(entry.detail)"
    if let percent = entry.batteryPercent { line += "  [battery \(percent)%]" }
    if let thermal = entry.thermal, thermal != .nominal { line += "  [\(thermal.display)]" }
    out(line)
}

// MARK: - `lidcode -- <command>`

/// Wrap one command in a keep-awake hold for exactly its lifetime.
///
/// Unlike the equivalent in the tool this is modelled on, the wrapper does not run
/// unguarded when the app is available: it registers a renewing lease first, so the
/// app's battery and thermal governor covers a wrapped command too. Only when the app
/// genuinely is not running does it fall back to a bare assertion — and it says so.
func runWrapped(_ argument: [String]) -> Never {
    guard !argument.isEmpty else { fail("usage: lidcode -- <command>") }
    let command = argument.joined(separator: " ")

    let assertion = PowerAssertion()
    assertion.acquire(reason: "lidcode -- \(command)")

    var token: String?
    let client = LineSocketClient(path: LidCodePath.appSocket.path)
    if (try? client.connect()) != nil,
       let response = try? client.roundTrip(
           AppRequest.claim(label: command, ttlSecond: 60, key: nil),
           expecting: AppResponse.self),
       case .token(let issued) = response {
        token = issued
    } else {
        FileHandle.standardError.write(Data(
            "lidcode: app not running, holding an unguarded assertion (no battery or thermal floor)\n".utf8))
    }

    // Renew well inside the 60s TTL so a stalled CLI cannot outlive its own claim.
    let renewTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.lidcode.cli.renew"))
    if let token {
        renewTimer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
        renewTimer.setEventHandler {
            _ = try? client.roundTrip(AppRequest.renew(token: token, ttlSecond: 60), expecting: AppResponse.self)
        }
        renewTimer.resume()
    }

    // A login shell so `&&`, pipes, and Homebrew/pyenv/nvm PATH resolve the way they
    // do interactively. Quote the whole command to keep it in one hold.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", command]

    func cleanUp() {
        renewTimer.cancel()
        if let token {
            _ = try? client.roundTrip(AppRequest.release(token: token), expecting: AppResponse.self)
        }
        assertion.release()
    }

    do {
        try process.run()
    } catch {
        cleanUp()
        fail("cannot run: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    cleanUp()
    exit(process.terminationStatus)
}

// MARK: - `lidcode codex <profile>`

/// Start one Codex profile without changing the environment of any other
/// Codex process. Each invocation gets its own CODEX_HOME, so two terminals can
/// stay logged into different accounts at the same time.
func runCodex(_ argument: [String]) -> Never {
    let profiles: [AIProfile]
    do {
        profiles = try AIProfileStore.load().filter { $0.provider == .codex }
    } catch { fail("cannot read AI profiles: \(error.localizedDescription)") }
    guard let query = argument.first else {
        fail("usage: lidcode codex <profile name or id> [codex arguments]; use --list to see profiles")
    }
    if query == "--list" {
        for profile in profiles { print("\(profile.name)\t\(profile.id)\t\(profile.expandedDirectory)") }
        exit(0)
    }
    let matches = profiles.filter { $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame }
    guard matches.count == 1, let profile = matches.first else {
        fail(matches.isEmpty ? "unknown Codex profile '\(query)'; add it in Options → Customize" :
             "ambiguous profile name '\(query)'; use the id from lidcode codex --list")
    }
    let home = profile.expandedDirectory

    // Replace this process instead of launching Codex through Foundation.Process.
    // Process creates a new process group on macOS; an interactive child then is
    // stopped by terminal job control because `lidcode` remains the foreground
    // group. An exec keeps Codex in the caller's foreground group while changing
    // only this process's CODEX_HOME, so other Codex sessions remain untouched.
    guard setenv("CODEX_HOME", home, 1) == 0 else {
        fail("cannot set CODEX_HOME: \(String(cString: strerror(errno)))")
    }

    let args = ["codex"] + Array(argument.dropFirst())
    var cArguments: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    cArguments.append(nil)
    cArguments.withUnsafeMutableBufferPointer { buffer in
        _ = execvp(buffer.baseAddress![0], buffer.baseAddress!)
    }

    let error = String(cString: strerror(errno))
    cArguments.dropLast().forEach { if let pointer = $0 { free(pointer) } }
    fail("cannot start Codex: \(error)")
}

// MARK: - Dispatch

let argument = Array(CommandLine.arguments.dropFirst())

if let separator = argument.firstIndex(of: "--") {
    runWrapped(Array(argument[(separator + 1)...]))
}

guard let command = argument.first else {
    out("""
    lidcode \(cliVersion) — keep a Mac awake for work that must finish

      lidcode status                     what is holding the Mac, and why
      lidcode health                     every check the menu bar draws, as text
      lidcode guard battery|temp|all on|off
                                         on  = stop at the 20% floor / sustained heat
                                         off = override it and keep going
      lidcode start [--timer 3h] [--mode smart|manual]
      lidcode stop
      lidcode lid on|off [--timer 8h]    closed-lid mode (needs the helper)
      lidcode autowatch on|off|toggle    detect known dev/AI processes
      lidcode watch <pattern>            add a process pattern
      lidcode unwatch <pattern>          remove one
      lidcode pattern                    list them
      lidcode claim <label> [--ttl 300] [--key K]   declare live work
      lidcode renew <token> [--ttl 300]
      lidcode release <token> | --key K
      lidcode lease                      what is currently claimed
      lidcode log [-n 20]                why sessions started and stopped
      lidcode -- <command>               hold for exactly one command
      lidcode setting                    show thresholds
      lidcode set --soft-battery 25 --idle-release 5m --charging-only on
      lidcode set --network-probe off    stop probing DNS and agent APIs
      lidcode set --hold 4h              how long a timed hold runs for
      lidcode set --sustained-heat 15m   how long it must stay hot before releasing
      lidcode hook install [--project]   hold the Mac only while Claude Code works
      lidcode codex <profile> [args]     start a configured Codex profile
      lidcode codex --list               list profile names and ids
      lidcode doctor                     check the install, find a stuck disablesleep
    """)
    exit(0)
}

let rest = Array(argument.dropFirst())
let second = flagValue("--timer", in: rest).flatMap(parseSecond)
let mode = HoldMode(rawValue: flagValue("--mode", in: rest) ?? "smart") ?? .smart
let ttl = flagValue("--ttl", in: rest).flatMap(parseSecond) ?? 300

switch command {
case "codex":
    runCodex(rest)

case "status":
    report(send(.status))

// The two persistent safety guards. These replaced a timed "keep going anyway"
// override, so the sense is inverted from the command that used to live here: `on` is
// the protected state, `off` is the override.
//
// Neither reaches the rules that are not waivable — the hard battery floor still forces
// a resumable sleep, and critical heat behind a shut lid still forces one. Turning a
// guard off waives the *soft* floor and the *chosen* ceiling. See `SafetyGovernor`.
case "guard":
    guard let target = rest.first,
          let state = rest.dropFirst().first,
          state == "on" || state == "off"
    else { fail("usage: lidcode guard battery|temp|all on|off") }

    let isOn = state == "on"
    var patch = SettingPatch()
    switch target {
    case "battery":         patch.isBatteryGuardOn = isOn
    case "temp", "thermal": patch.isThermalGuardOn = isOn
    case "all", "both":
        patch.isBatteryGuardOn = isOn
        patch.isThermalGuardOn = isOn
    default: fail("usage: lidcode guard battery|temp|all on|off")
    }
    report(send(.updateSetting(patch)))

// Kept as an alias so existing scripts do not break, and mapped rather than emulated:
// there is no bounded window any more, so `override <anything>` turns both guards off
// and `override off` turns them back on. Announced on stderr because the semantics
// genuinely changed — a waiver that used to expire on its own now does not.
case "override":
    let isOff = rest.first == "off"
    FileHandle.standardError.write(Data(
        ("lidcode: `override` is now `guard`. Turning both guards "
         + (isOff ? "on" : "off") + " (this no longer expires on its own)\n").utf8))
    report(send(.updateSetting(SettingPatch(
        isBatteryGuardOn: isOff, isThermalGuardOn: isOff))))

case "health":
    report(send(.health, timeoutSecond: 15))

case "start":
    report(send(.start(second: second, mode: mode)))

case "stop":
    report(send(.stop))

case "lid":
    guard let state = rest.first, state == "on" || state == "off" else {
        fail("usage: lidcode lid on|off [--timer 8h] [--mode manual|smart]")
    }
    // Default to .manual so `lidcode lid on --timer 8h` keeps disablesleep for the
    // full timer regardless of agent activity. Without this the shared default of
    // .smart means a lid-on with no running session releases after idleReleaseSecond
    // (~600 s) — making the timer meaningless for non-agent use. An explicit
    // `--mode smart` still honours the caller's intent.
    let lidMode = HoldMode(rawValue: flagValue("--mode", in: rest) ?? "manual") ?? .manual
    report(send(.clamshell(isOn: state == "on", second: second, mode: lidMode)))

case "autowatch":
    guard let state = rest.first else { fail("usage: lidcode autowatch on|off|toggle") }
    switch state {
    case "on":     report(send(.autowatch(isOn: true)))
    case "off":    report(send(.autowatch(isOn: false)))
    case "toggle":
        if case .snapshot(let snap) = send(.status) {
            report(send(.autowatch(isOn: !snap.isAwakeHeld)))
        }
    default: fail("usage: lidcode autowatch on|off|toggle")
    }

case "watch":
    guard let pattern = rest.first else { fail("usage: lidcode watch <pattern>") }
    report(send(.watch(pattern: pattern)))

case "unwatch":
    guard let pattern = rest.first else { fail("usage: lidcode unwatch <pattern>") }
    report(send(.unwatch(pattern: pattern)))

case "pattern":
    report(send(.pattern))

case "claim":
    guard let label = rest.first, !label.hasPrefix("--") else {
        fail("usage: lidcode claim <label> [--ttl 300] [--key K]")
    }
    report(send(.claim(label: label, ttlSecond: ttl, key: flagValue("--key", in: rest))))

case "renew":
    guard let token = rest.first else { fail("usage: lidcode renew <token> [--ttl 300]") }
    report(send(.renew(token: token, ttlSecond: ttl)))

case "release":
    if let key = flagValue("--key", in: rest) {
        report(send(.releaseKey(key: key)))
    } else if let token = rest.first, !token.hasPrefix("--") {
        report(send(.release(token: token)))
    } else {
        fail("usage: lidcode release <token> | --key K")
    }

case "lease":
    report(send(.lease))

case "log":
    let limit = flagValue("-n", in: rest).flatMap(Int.init) ?? 20
    report(send(.recentLog(limit: limit)))

case "setting":
    report(send(.settingList))

case "set":
    var patch = SettingPatch()
    patch.softBatteryPercent = flagValue("--soft-battery", in: rest).flatMap(Int.init)
    patch.hardBatteryPercent = flagValue("--hard-battery", in: rest).flatMap(Int.init)
    patch.idleReleaseSecond = flagValue("--idle-release", in: rest).flatMap(parseSecond)
    patch.thermalCeiling = flagValue("--thermal-ceiling", in: rest).flatMap(ThermalLevel.init(rawValue:))
    if let charging = flagValue("--charging-only", in: rest) {
        patch.isChargingOnly = charging == "on" || charging == "true"
    }
    if let probe = flagValue("--network-probe", in: rest) {
        patch.isNetworkProbeOn = probe == "on" || probe == "true"
    }
    if let dim = flagValue("--dim-on-lid-close", in: rest) {
        patch.isDimOnLidCloseOn = dim == "on" || dim == "true"
    }
    patch.holdSecond = flagValue("--hold", in: rest).flatMap(parseSecond)
    patch.sustainedHeatSecond = flagValue("--sustained-heat", in: rest).flatMap(parseSecond)
    guard !patch.isEmpty else {
        fail("usage: lidcode set [--soft-battery 25] [--hard-battery 5] [--idle-release 5m] "
             + "[--thermal-ceiling serious] [--charging-only on|off] [--network-probe on|off] "
             + "[--dim-on-lid-close on|off] [--hold 4h] [--sustained-heat 15m]")
    }
    report(send(.updateSetting(patch)))

case "hook":
    Hook.run(rest)

case "doctor":
    Doctor.run()

case "--version", "-v", "version":
    out(cliVersion)

case "help", "--help", "-h":
    out("run `lidcode` with no argument for the command list")

default:
    fail("unknown command '\(command)'. Run `lidcode` for the command list")
}
