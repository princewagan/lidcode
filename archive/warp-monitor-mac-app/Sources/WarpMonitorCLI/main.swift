import Foundation
import AppKit
import WarpMonitor

// MARK: - CLI entry point
//
// Modes:
//   --once          Read once, print JSON to stdout, exit. (debug / scripting)
//   --push          Run continuously, push to /api/push on state change + 60s heartbeat.
//                   Reads PUSH_SECRET and PUSH_URL from ~/.warp-monitor.env.
//   (no flags)      Run continuously, print JSON to stdout on every state change. (debug)
//
// Optional flags (all modes):
//   --log-path <path>   Override warp.log path
//   --db-path  <path>   Override warp.sqlite path
//   --print             When combined with --push, also print JSON to stdout

let args = CommandLine.arguments
let singleShot   = args.contains("--once")
let pushMode     = args.contains("--push")
let printAlso    = args.contains("--print")

var logPath = LogTailer.defaultLogPath
if let idx = args.firstIndex(of: "--log-path"), idx + 1 < args.count {
    logPath = args[idx + 1]
}

var dbPath = SQLiteReader.defaultDBPath
if let idx = args.firstIndex(of: "--db-path"), idx + 1 < args.count {
    dbPath = args[idx + 1]
}

// --config-path allows overriding ~/.warp-monitor.env for testing
var configPath = "~/.warp-monitor.env"
if let idx = args.firstIndex(of: "--config-path"), idx + 1 < args.count {
    configPath = args[idx + 1]
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

// MARK: - Single-shot mode

if singleShot {
    let manager = StateManager(dbPath: dbPath, logPath: logPath)
    let state = manager.refresh()
    if let data = try? encoder.encode(state),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    exit(0)
}

// MARK: - Push mode (daemon)

if pushMode {
    let manager = StateManager(dbPath: dbPath, logPath: logPath)
    manager.pushEnabled = true
    manager.printEnabled = printAlso

    // Provide Warp running status for the push daemon.
    manager.warpRunningProvider = {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.warp.Warp-Stable"
        ).isEmpty
    }

    // Configure pusher from config file (default: ~/.warp-monitor.env)
    manager.configurePusher(configPath: configPath)

    if let err = manager.pusher?.configurationError {
        fputs("[warp-monitor] WARNING: \(err)\n", stderr)
        fputs("[warp-monitor] Push will not work until the config file is created.\n", stderr)
        fputs("[warp-monitor] Create ~/.warp-monitor.env with:\n", stderr)
        fputs("[warp-monitor]   PUSH_SECRET=<your secret>\n", stderr)
        fputs("[warp-monitor]   PUSH_URL=https://<your-project>.vercel.app/api/push\n", stderr)
    } else {
        fputs("[warp-monitor] Push mode active. Pushing to configured URL on state change.\n", stderr)
        fputs("[warp-monitor] Heartbeat every 60s regardless of state change.\n", stderr)
    }

    if printAlso {
        manager.onStateUpdated = { state in
            if let data = try? encoder.encode(state),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                print("---")
                fflush(stdout)
            }
        }
    }

    manager.start()

    // Register for Mac wake-from-sleep notifications so the CLI daemon recovers quickly.
    // Uses NSWorkspace notification center — available in all macOS processes, not just apps.
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: nil
    ) { _ in
        fputs("[warp-monitor] Wake from sleep — forcing re-query.\n", stderr)
        manager.forceRefreshAfterWake()
    }

    RunLoop.main.run()
    exit(0)
}

// MARK: - Continuous stdout mode (default, no flags)

let manager = StateManager(dbPath: dbPath, logPath: logPath)
manager.warpRunningProvider = {
    !NSRunningApplication.runningApplications(
        withBundleIdentifier: "dev.warp.Warp-Stable"
    ).isEmpty
}
manager.onStateUpdated = { state in
    if let data = try? encoder.encode(state),
       let json = String(data: data, encoding: .utf8) {
        print(json)
        print("---")
        fflush(stdout)
    }
}
manager.start()
RunLoop.main.run()
