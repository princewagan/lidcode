import SwiftUI
import LidCodeKit

/// Every threshold that decides when the Mac is allowed to sleep, editable in place.
///
/// These were CLI-only (`lidcode set`), which put the numbers that govern an overnight
/// run behind a command you have to remember. The panel already *draws* the floors —
/// the battery bar deepens at the soft one — so it should be able to move them.
///
/// Changes apply to the live governor immediately, not on next launch: a floor you
/// just raised should protect the run you are in the middle of.
///
/// The hold duration and the two waivable guards moved in here from directly under the
/// power button. They were the panel's biggest single source of text — a slider with a
/// label, a scale, a readout, and two buttons carrying sentences like "Disable on 15m hot
/// temperature" — sitting between the switch and the readouts, which is the worst place on
/// the panel for anything you touch once a week. Collapsed, they cost a chevron; expanded,
/// they are exactly where you would look for a setting.
///
/// Ordered by how often they are changed, not by subject: duration first (per run), then
/// the guards (per run, occasionally), then the floors and behaviour (once, ever).
struct SettingSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    private var setting: Setting { model.setting }

    /// Coarse, human choices rather than a free-entry field. A 7-second idle release
    /// is not a thing anyone wants, and a text field in a menu-bar panel is a way to
    /// find out what happens when you type "abc".
    private static let idleChoice: [(label: String, second: Int)] = [
        ("1m", 60), ("5m", 300), ("10m", 600), ("30m", 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    SectionLabel(text: "Settings", trailing: isExpanded ? nil : summary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                DurationSlider(second: setting.holdSecond) { model.setHoldSecond($0) }
                guardRow
                Divider().opacity(0.5)
                battery
                Divider().opacity(0.5)
                behaviour
            }
        }
    }

    /// The one fact worth keeping on the collapsed row: how long a hold runs for.
    ///
    /// The summary used to read "60% · 5m idle" — two numbers nobody changes, printed
    /// permanently. The duration is different: it is now the only setting in here that is
    /// touched per run, and burying it behind a chevron with no trace would make it
    /// genuinely hard to find. Two characters is not wordiness.
    private var summary: String {
        DurationSlider.display(second: setting.holdSecond)
    }

    // MARK: - Guards

    /// Side by side, because they are the same kind of decision made about two different
    /// resources, and stacking them implied a precedence that does not exist — neither
    /// guard outranks the other.
    ///
    /// Labels are down to two or three words each. The full consequence — which floor,
    /// what happens when it is waived, what still cannot be waived — is in each button's
    /// tooltip, because it is a paragraph and it was previously being printed in a 150pt
    /// column where it wrapped to three lines.
    private var guardRow: some View {
        HStack(spacing: 7) {
            GuardToggle(
                isOn: setting.isBatteryGuardOn,
                onLabel: "Stop at \(setting.softBatteryPercent)%",
                offLabel: "Battery waived",
                symbolName: "battery.25",
                detail: setting.isBatteryGuardOn
                    ? "Releases the hold at \(setting.softBatteryPercent)% so the Mac sleeps with enough charge to resume. Click to waive it."
                    : "Waived. The hard \(setting.hardBatteryPercent)% floor still forces sleep — that one cannot be turned off.",
                onToggle: { model.setBatteryGuard($0) }
            )
            GuardToggle(
                isOn: setting.isThermalGuardOn,
                onLabel: "Stop when hot",
                offLabel: "Heat waived",
                symbolName: "thermometer.medium",
                detail: setting.isThermalGuardOn
                    ? "Releases the hold after \(setting.sustainedHeatSecond / 60) continuous minutes at or above \(setting.thermalCeiling.display). A brief spike is ignored. Click to waive it."
                    : "Waived. Critical heat with the lid shut still forces sleep — there is no airflow to recover through.",
                onToggle: { model.setThermalGuard($0) }
            )
        }
    }

    // MARK: - Floors

    private var battery: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: Binding(
                get: { setting.softBatteryPercent },
                set: { model.updateSetting(SettingPatch(softBatteryPercent: $0)) }
            ), in: Setting.softBatteryRange, step: 5) {
                row("Sleep at", "\(setting.softBatteryPercent)%",
                    help: "Release the hold and sleep normally, with headroom to resume.")
            }

            Stepper(value: Binding(
                get: { setting.hardBatteryPercent },
                set: { model.updateSetting(SettingPatch(hardBatteryPercent: $0)) }
            ), in: Setting.hardBatteryRange, step: 1) {
                row("Force sleep at", "\(setting.hardBatteryPercent)%",
                    help: "Last resort. Beats every power assertion, not just LidCode's.")
            }

            HStack {
                Text("Back off when").font(.system(size: 11))
                Spacer()
                Picker("", selection: Binding(
                    get: { setting.thermalCeiling },
                    set: { model.updateSetting(SettingPatch(thermalCeiling: $0)) }
                )) {
                    ForEach(Setting.thermalCeilingChoice, id: \.self) { level in
                        Text(level.display).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 108)
            }
            .help("Thermal pressure at which the hold is released. LidCode reads the state macOS reports; it does not control fans.")
        }
        .controlSize(.small)
        // System controls draw themselves in the user's accent colour, which is blue by
        // default — so the drawer was the one place a second hue could still get in
        // without any code asking for it. Tinting hands them to the same family as
        // everything else. See `Palette`.
        .tint(Palette.brand)
    }

    // MARK: - Behaviour

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Release after").font(.system(size: 11))
                Spacer()
                Picker("", selection: Binding(
                    get: { setting.idleReleaseSecond },
                    set: { model.updateSetting(SettingPatch(idleReleaseSecond: $0)) }
                )) {
                    ForEach(Self.idleChoice, id: \.second) { choice in
                        Text(choice.label).tag(choice.second)
                    }
                    // A hand-edited config can hold a value that is not on the menu.
                    // Without this the picker would show blank and silently rewrite it
                    // the first time the section is opened.
                    if !Self.idleChoice.contains(where: { $0.second == setting.idleReleaseSecond }) {
                        Text("\(setting.idleReleaseSecond)s").tag(setting.idleReleaseSecond)
                    }
                }
                .labelsHidden()
                .frame(width: 108)
            }
            .help("Smart mode only: how long every lease must be gone before the Mac is released.")

            Toggle("Watch for known dev and AI processes", isOn: Binding(
                get: { model.snapshot.isAutoWatchOn },
                set: { model.setAutoWatch($0) }
            ))
            .help("Presence-based detection as a fallback. `lidcode claim` is the precise path: the work says when it starts and stops.")

            Toggle("Hold only while plugged in", isOn: Binding(
                get: { setting.isChargingOnly },
                set: { model.updateSetting(SettingPatch(isChargingOnly: $0)) }
            ))

            Toggle("Check services over the network", isOn: Binding(
                get: { setting.isNetworkProbeOn },
                set: { model.setNetworkProbe($0) }
            ))
            .help("DNS plus a HEAD request to the API of whichever agent holds a lease. Off means LidCode makes no outbound requests at all.")
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .tint(Palette.brand)
    }

    private func row(_ title: String, _ value: String, help: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11))
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(help)
    }
}
