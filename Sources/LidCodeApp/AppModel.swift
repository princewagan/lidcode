import Foundation
import SwiftUI
import UserNotifications
import LidCodeKit


/// Bridges the runtime to SwiftUI and hosts the socket the CLI talks to.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = RuntimeSnapshot()
    @Published private(set) var setting: Setting = .default
    @Published var alert: String?

    /// Whether the settings drawer is open. This lives here rather than as `@State` in
    /// the view because the window has to resize itself when it opens, and the panel
    /// controller can only see state it can subscribe to. Keeping it here also means a
    /// drawer you opened is still open the next time you click the icon.
    ///
    /// It is the last one. The panel used to carry four of these — agent, health,
    /// activity, settings — and each disclosure was a section that had to be read past
    /// to reach the switch. The other three sections are gone; see `MenuView`.
    @Published var isSettingExpanded = false

    /// `nonisolated` on purpose: the runtime is internally queue-confined and safe to
    /// call from any thread, and the CLI socket handler must reach it without hopping
    /// to the main actor — a `lidcode status` in a script cannot wait on UI work.
    nonisolated private let runtime = LidCodeRuntime()
    private var server: LineSocketServer?

    // Push client (W10). One instance for the lifetime of the app.
    // If LidCodePusher is not yet compiled (Push/ dir is empty), the call below
    // is wrapped in #if and will not block the build.
    // The file ownership note in the plan says W3 holds this; we wire it here.
    nonisolated private let pusher = LidCodePusher()

    init() {
        runtime.onChange = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snapshot
                // The log and the metric history are deliberately *not* pulled here any
                // more. Both were copied out of the runtime on every publish — a 12-entry
                // log and 48 samples, every 5 seconds, on the main actor, to feed an
                // activity list and a sparkline that no longer exist. Deleting the views
                // without deleting these would have kept the cost and lost the reason.
                // `lidcode log` still reads the same history on demand.
                //
                // The panel draws thresholds, not just readings — a battery bar that
                // deepens at the soft floor has to know where the floor moved to.
                self.setting = self.runtime.currentSetting
                self.refreshHelperReadiness()
            }
            // Push to Supabase off the main thread (W10). Non-blocking; silent on failure.
            Task.detached { [weak self] in
                guard let self else { return }
                self.pusher.pushIfChanged(snapshot)
            }
        }
        runtime.onAlert = { [weak self] message in
            Task { @MainActor in
                self?.alert = message
                self?.notify(message)
            }
        }
    }

    func start() {
        runtime.start()
        startServer()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        snapshot = runtime.snapshot
        setting = runtime.currentSetting
        runtime.refreshHealth()
    }

    /// Wired to app termination. Anything turned on must come back off here — the
    /// helper's deadman switch is the backstop, not the plan.
    func shutdown() {
        server?.stop()
        runtime.shutdown()
    }

    // MARK: - The one switch

    /// True when LidCode is holding the Mac awake. The panel has exactly one primary
    /// control now, so "enabled" has to mean one unambiguous thing — and closed-lid is
    /// the state people actually want, because a hold that dies when you shut the lid
    /// does not survive the walk to the sofa.
    var isEnabled: Bool { snapshot.isAwakeHeld || snapshot.isClamshellActive }

    /// Set while a helper round trip is in flight, so the button can say so rather than
    /// looking dead. The call underneath is non-blocking now (see `setClamshell`), which
    /// is what stopped a wedged helper from freezing the whole app — but non-blocking
    /// means the answer arrives later, and a control with no pending state reads as
    /// broken for those few hundred milliseconds.
    @Published private(set) var isSwitching = false

    /// The single enable/disable action.
    ///
    /// Turning it on asks for closed-lid protection and falls back to a plain hold when
    /// the root helper is not installed. Falling back rather than refusing is deliberate:
    /// "keep my Mac awake" is still mostly satisfiable without root, and an error where a
    /// partial success was available is the kind of dead end this panel used to be full of.
    func setEnabled(_ isOn: Bool) {
        alert = nil
        guard !isSwitching else { return }

        guard isOn else {
            isSwitching = true
            runtime.setClamshell(false, second: nil, mode: .manual) { [weak self] _ in
                guard let self else { return }
                self.runtime.endHold(reason: .userStopped)
                self.isSwitching = false
            }
            return
        }

        let second = setting.holdSecond
        // Picking a capability you do not have yet should install it, not scold you. The
        // password prompt is a better answer than an error banner.
        guard HelperInstaller.isInstalled else {
            installHelper()
            guard isHelperReady else {
                // No root helper and the user declined to install one. Hold anyway — the
                // Mac still stays awake, it just will not survive the lid closing.
                runtime.beginHold(second: second, mode: .manual)
                return
            }
            enableClamshell(second: second)
            return
        }
        enableClamshell(second: second)
    }

    private func enableClamshell(second: Int) {
        isSwitching = true
        // Manual mode: hold for the full duration regardless of whether an agent session
        // is running. Smart mode would kill a by-hand hold after 10 minutes of idleness —
        // a hold the user explicitly turned on and timed on the slider should not die
        // in the background because no Claude session happened to be active.
        runtime.setClamshell(true, second: second, mode: .manual) { [weak self] result in
            guard let self else { return }
            self.isSwitching = false
            if case .failure(let error) = result {
                // The privileged half failed, so say so — and still keep the Mac awake,
                // which is the part that does not need root.
                self.alert = error.localizedDescription
                self.runtime.beginHold(second: second, mode: .manual)
            }
        }
    }

    /// Re-arms the hold with a new duration without cycling the switch off and on. Used
    /// by the duration slider: dragging it while a session is live should extend that
    /// session, not end it.
    func setHoldSecond(_ second: Int) {
        _ = runtime.updateSetting(SettingPatch(holdSecond: second))
        guard isEnabled else { return }
        // extendHold updates the deadline without touching mode, so dragging the slider
        // during a running .smart auto-watch hold cannot silently convert it to .manual
        // and disable the idle-release for the rest of the session.
        runtime.extendHold(second: second)
    }

    /// Forwards the immediate lid-check to the runtime.
    ///
    /// Called from the screen-sleep notification so dimming reacts within a tick rather
    /// than waiting up to 10s for the cache and timer to align.
    func checkLidNow() {
        runtime.checkLidNow()
    }

    // MARK: - Safety guards

    /// The two rules the user is allowed to waive, as persistent toggles rather than the
    /// timed popup this replaced. A banner that appears only once the Mac has already
    /// stopped is a control you cannot find when you want it — which is *before* the
    /// overnight run, not after it died.
    func setBatteryGuard(_ isOn: Bool) {
        alert = nil
        runtime.setBatteryGuard(isOn)
    }

    func setThermalGuard(_ isOn: Bool) {
        alert = nil
        runtime.setThermalGuard(isOn)
    }

    func refreshHealth() {
        alert = nil
        // Refresh means "look again at everything", which includes which agent apps
        // are installed — otherwise a freshly installed Cursor keeps its placeholder
        // glyph until the app restarts.
        AppIconResolver.forget()
        runtime.refreshHealth()
    }

    func setNetworkProbe(_ isOn: Bool) {
        _ = runtime.updateSetting(SettingPatch(isNetworkProbeOn: isOn))
        runtime.refreshHealth()
    }

    /// Override the thermal/battery guard. Part of the F1-F4 button cycle.
    /// Only bypasses soft guards — hard battery floor and critical-heat+closed are always enforced.
    func setGuardOverride(_ isOn: Bool) {
        runtime.setGuardOverride(isOn)
    }

    func setAutoWatch(_ isOn: Bool) {
        runtime.setAutoWatch(isOn)
    }

    // MARK: - Helper

    /// Whether closed-lid mode can be offered at all.
    @Published private(set) var isHelperReady = HelperInstaller.isInstalled
    @Published private(set) var isInstallingHelper = false

    func installHelper() {
        guard !isInstallingHelper else { return }
        isInstallingHelper = true
        alert = nil
        do {
            try HelperInstaller.install()
            isHelperReady = true
            // The daemon is new, so the health panel's helper row is stale.
            runtime.refreshHealth()
        } catch HelperInstaller.Failure.cancelled {
            // Dismissing the password prompt is a decision, not an error to report back.
        } catch {
            alert = error.localizedDescription
        }
        isInstallingHelper = false
    }

    /// Re-checked on every runtime publish so the row updates if the helper is
    /// installed or removed from outside the app — `Script/install-helper.sh` in a
    /// Terminal, or `uninstall-helper.sh`.
    private func refreshHelperReadiness() {
        let isReady = HelperInstaller.isInstalled
        if isReady != isHelperReady { isHelperReady = isReady }
    }

    /// Applied to the live governor, not just saved — see `LidCodeRuntime.updateSetting`.
    /// The health sweep re-runs because several checks are read against these
    /// thresholds, so a floor you just moved should recolour the panel now rather than
    /// at the next 30-second sweep.
    func updateSetting(_ patch: SettingPatch) {
        setting = runtime.updateSetting(patch)
        runtime.refreshHealth()
    }

    // MARK: - CLI server

    private func startServer() {
        try? LidCodePath.ensureSupportDirectory()
        let server = LineSocketServer(path: LidCodePath.appSocket.path) { [weak self] line in
            guard let self else { return nil }
            let request = (try? Wire.decode(AppRequest.self, from: line)) ?? .status
            let response = self.handleSync(request)
            return try? Wire.encoder.encode(response)
        }
        do {
            try server.start(mode: 0o600)
            self.server = server
            runtime.setSocketBound(true)
        } catch {
            // Swallowing this is what made the failure invisible: the app runs fine,
            // the menu looks normal, and every `lidcode` command reports "LidCode is not
            // running" with no way to tell that apart from the app being closed.
            runtime.setSocketBound(false, detail: error.localizedDescription)
            alert = "CLI socket unavailable: \(error.localizedDescription)"
        }
    }

    /// Runs on a socket connection queue. The runtime is internally queue-confined,
    /// so this hops to it rather than to the main actor — a `lidcode status` in a
    /// script must not be able to block on UI work.
    nonisolated private func handleSync(_ request: AppRequest) -> AppResponse {
        switch request {
        case .status:
            return .snapshot(runtime.snapshot)

        case .start(let second, let mode):
            runtime.beginHold(second: second, mode: mode)
            return .ok("keep-awake on (\(mode.rawValue))")

        case .stop:
            runtime.endHold(reason: .userStopped)
            return .ok("keep-awake off")

        case .clamshell(let isOn, let second, let mode):
            do {
                // The *blocking* form on purpose. This runs on the CLI's own connection
                // queue, never on main, and `lidcode lid on` has to be able to print the
                // failure — a command that returns "ok" before the root helper has agreed
                // is a lie a script will act on.
                try runtime.setClamshellBlocking(isOn, second: second, mode: mode)
                return .ok("closed-lid \(isOn ? "on" : "off")")
            } catch {
                return .failed(error.localizedDescription)
            }

        case .autowatch(let isOn):
            runtime.setAutoWatch(isOn)
            return .ok("auto-watch \(isOn ? "on" : "off")")

        case .watch(let pattern):
            runtime.addPattern(pattern)
            return .ok("watching \(pattern)")

        case .unwatch(let pattern):
            runtime.removePattern(pattern)
            return .ok("stopped watching \(pattern)")

        case .pattern:
            return .text(runtime.currentPattern)

        case .claim(let label, let ttlSecond, let key):
            return .token(runtime.claim(label: label, ttlSecond: ttlSecond, key: key))

        case .releaseKey(let key):
            return runtime.release(key: key) ? .ok("released") : .failed("no lease for key")

        case .settingList:
            let setting = runtime.currentSetting
            return .text([
                "soft-battery    \(setting.softBatteryPercent)%",
                "hard-battery    \(setting.hardBatteryPercent)%",
                "thermal-ceiling \(setting.thermalCeiling.rawValue)",
                "idle-release    \(setting.idleReleaseSecond)s",
                "charging-only   \(setting.isChargingOnly)",
                "network-probe   \(setting.isNetworkProbeOn)",
                "dim-on-lid-close \(setting.isDimOnLidCloseOn)",
            ])

        case .updateSetting(let patch):
            let setting = runtime.updateSetting(patch)
            return .ok("soft-battery \(setting.softBatteryPercent)%, "
                       + "hard-battery \(setting.hardBatteryPercent)%, "
                       + "thermal-ceiling \(setting.thermalCeiling.rawValue), "
                       + "idle-release \(setting.idleReleaseSecond)s, "
                       + "charging-only \(setting.isChargingOnly), "
                       + "network-probe \(setting.isNetworkProbeOn)")

        case .renew(let token, let ttlSecond):
            return runtime.renew(token: token, ttlSecond: ttlSecond)
                ? .ok("renewed")
                : .failed("unknown or expired token, claim again")

        case .release(let token):
            return runtime.release(token: token) ? .ok("released") : .failed("unknown token")

        case .lease:
            let lease = runtime.activeLease
            return .text(lease.isEmpty ? ["nothing claimed"] : lease.map(\.display))

        case .recentLog(let limit):
            return .log(runtime.recentLog(limit: limit))

        case .health:
            // Blocks this connection's queue until the sweep lands — see `healthNow`.
            guard let report = runtime.healthNow() else {
                return .text(["checking… run again in a moment"])
            }
            var line: [String] = []
            for group in HealthGroup.allCases {
                let check = report.check(in: group)
                guard !check.isEmpty else { continue }
                line.append("\(group.display.uppercased())  [\(report.state(of: group).display)]")
                line += check.map { "  \($0.line)" }
            }
            line.append("")
            line.append("overall: \(report.overall.display) · checked \(report.at.formatted(date: .omitted, time: .standard))")
            return .text(line)

        case .notify(let title, let body):
            notify("\(title): \(body)")
            return .ok("sent")
        }
    }

    nonisolated private func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "LidCode"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Wake recovery

    /// Forwards the post-wake recovery call to the underlying runtime.
    ///
    /// Called from `AppDelegate.wakeUp()` after `NSWorkspace.didWakeNotification` or
    /// `NSWorkspace.screensDidWakeNotification`. Kept here rather than in the delegate
    /// because the runtime is a private implementation detail of AppModel.
    func recoverAfterWake() {
        runtime.recoverAfterWake()
    }
}
