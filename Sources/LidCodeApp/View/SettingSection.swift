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
                // Duration slider moved to main panel (J5). Only guards + floors here.
                guardRow
                Divider().opacity(0.5)
                battery
                Divider().opacity(0.5)
                behaviour
                Divider().opacity(0.5)
                memory
                Divider().opacity(0.5)
                menuBarSection
            }
        }
    }

    /// The one fact worth keeping on the collapsed row.
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
                onLabel: "Sleep at \(setting.softBatteryPercent)%",
                offLabel: "No battery floor",
                symbolName: "battery.25",
                detail: setting.isBatteryGuardOn
                    ? "ON. Releases the hold at \(setting.softBatteryPercent)% so the Mac sleeps with enough charge to resume. Click to switch this guard off."
                    : "OFF. Nothing stops the run as the battery drains, except the hard \(setting.hardBatteryPercent)% floor — that one cannot be turned off. Click to switch the guard back on.",
                onToggle: { model.setBatteryGuard($0) }
            )
            GuardToggle(
                isOn: setting.isThermalGuardOn,
                onLabel: "Sleep when hot",
                offLabel: "No heat limit",
                symbolName: "thermometer.medium",
                detail: setting.isThermalGuardOn
                    ? "ON. Releases the hold after \(setting.sustainedHeatSecond / 60) continuous minutes at or above \(setting.thermalCeiling.display). A brief spike is ignored. Click to switch this guard off."
                    : "OFF. Heat will not stop the run, except critical heat with the lid shut — there is no airflow to recover through, so that one cannot be turned off. Click to switch the guard back on.",
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
                Text("Too hot means").font(.system(size: 11))
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

            // Renamed from "Hold only while plugged in", which read as a restriction on
            // some other feature rather than a rule about when the Mac may sleep. The
            // label now says what happens, and the tooltip says when you would want it.
            Toggle("Let the Mac sleep when unplugged", isOn: Binding(
                get: { setting.isChargingOnly },
                set: { model.updateSetting(SettingPatch(isChargingOnly: $0)) }
            ))
            .help("OFF (normal): LidCode keeps the Mac awake on battery too, until the battery floor stops it. ON: unplugging the charger ends the hold straight away, whatever the battery level.")

            Toggle("Check services over the network", isOn: Binding(
                get: { setting.isNetworkProbeOn },
                set: { model.setNetworkProbe($0) }
            ))
            .help("DNS plus a HEAD request to the API of whichever agent holds a lease. Off means LidCode makes no outbound requests at all.")

            Toggle("Dim screen when lid is shut", isOn: Binding(
                get: { setting.isDimOnLidCloseOn },
                set: { model.updateSetting(SettingPatch(isDimOnLidCloseOn: $0)) }
            ))
            .help("Turns the built-in display down to minimum while the lid is closed. Put back when you open it.")
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

    // MARK: - Menu bar visibility toggles (I1, I2)

    /// Six toggles controlling which elements appear in the menu bar.
    /// All default to enabled (I2). Each toggle hides its element only — it never
    /// disables the underlying feature.
    /// Memory is display-only — nothing here can end a hold, so these are all about
    /// when to *say* something rather than when to act.
    ///
    /// The two thresholds are swap percentages, not memory percentages. Free memory
    /// stays misleadingly high while the compressor works; swap is what actually
    /// correlates with the machine feeling slow.
    private var memory: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Warn about memory pressure", isOn: Binding(
                get: { setting.isMemoryWarningOn },
                set: { model.updateSetting(SettingPatch(isMemoryWarningOn: $0)) }
            ))
            .font(.system(size: 11))
            .help("Adds a memory row to the panel and a chip icon to the menu bar. Never ends a hold.")

            if setting.isMemoryWarningOn {
                Stepper(value: Binding(
                    get: { setting.memoryWarnSwapPercent },
                    set: { model.updateSetting(SettingPatch(memoryWarnSwapPercent: $0)) }
                ), in: Setting.memoryWarnSwapRange, step: 5) {
                    row("Warn at swap", "\(setting.memoryWarnSwapPercent)%",
                        help: "Orange chip. The kernel's own pressure level still counts — this only raises it, never lowers it.")
                }

                Stepper(value: Binding(
                    get: { setting.memoryCriticalSwapPercent },
                    set: { model.updateSetting(SettingPatch(memoryCriticalSwapPercent: $0)) }
                ), in: Setting.memoryCriticalSwapRange, step: 5) {
                    row("Critical at swap", "\(setting.memoryCriticalSwapPercent)%",
                        help: "Red chip. Kept above the warn threshold automatically.")
                }

                Stepper(value: Binding(
                    get: { setting.memoryAppRowCount },
                    set: { model.updateSetting(SettingPatch(memoryAppRowCount: $0)) }
                ), in: Setting.memoryAppRowRange, step: 1) {
                    row("Apps listed", "\(setting.memoryAppRowCount)",
                        help: "How many of the biggest apps the panel names.")
                }
            }
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MENU BAR ICONS".uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.3)

            Toggle("State icon (bolt / lid)", isOn: Binding(
                get: { setting.menuBarShowStateIcon },
                set: { model.updateSetting(SettingPatch(menuBarShowStateIcon: $0)) }
            ))

            Toggle("Active sessions badge", isOn: Binding(
                get: { setting.menuBarShowActiveBadge },
                set: { model.updateSetting(SettingPatch(menuBarShowActiveBadge: $0)) }
            ))

            Toggle("Blocked sessions badge", isOn: Binding(
                get: { setting.menuBarShowBlockedBadge },
                set: { model.updateSetting(SettingPatch(menuBarShowBlockedBadge: $0)) }
            ))

            Toggle("Error sessions badge", isOn: Binding(
                get: { setting.menuBarShowErrorBadge },
                set: { model.updateSetting(SettingPatch(menuBarShowErrorBadge: $0)) }
            ))

            Toggle("Temp warning icon", isOn: Binding(
                get: { setting.menuBarShowTempWarnIcon },
                set: { model.updateSetting(SettingPatch(menuBarShowTempWarnIcon: $0)) }
            ))
            .help("Orange thermometer when temp is high but not blocking.")

            Toggle("Guard alert icon", isOn: Binding(
                get: { setting.menuBarShowAlertIcon },
                set: { model.updateSetting(SettingPatch(menuBarShowAlertIcon: $0)) }
            ))
            .help("Red thermometer or red battery when a guard is actively blocking the hold.")
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .tint(Palette.brand)
    }
}
