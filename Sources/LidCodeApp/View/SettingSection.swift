import SwiftUI
import LidCodeKit

/// Everyday preferences. Technical thresholds remain in the configuration and CLI.
struct SettingSection: View {
    @AppStorage("showMemoryList") private var showMemoryList = true
    @AppStorage("appTheme") private var themeName = AppTheme.blue.rawValue
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    private var setting: Setting { model.setting }
    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isExpanded {
                Stepper(value: Binding(
                    get: { setting.softBatteryPercent },
                    set: { model.updateSetting(SettingPatch(softBatteryPercent: $0)) }
                ), in: Setting.softBatteryRange, step: 5) {
                    HStack {
                        Text("Sleep below")
                        Text("\(setting.softBatteryPercent)% battery")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .disabled(!setting.isBatteryGuardOn)
                .help(setting.isBatteryGuardOn
                      ? "Let your Mac sleep when the battery reaches this level."
                      : "Battery protection is disabled in your configuration.")

                Toggle("Keep awake only when plugged in", isOn: Binding(
                    get: { setting.isChargingOnly },
                    set: { model.updateSetting(SettingPatch(isChargingOnly: $0)) }
                ))

                Divider().opacity(0.5)

                Toggle("Show memory list", isOn: $showMemoryList)

                Toggle("Show memory warnings", isOn: Binding(
                    get: { setting.isMemoryWarningOn },
                    set: { model.updateSetting(SettingPatch(isMemoryWarningOn: $0)) }
                ))
                .help("Warn when memory is low. This does not stop your work.")

                Toggle("Connect to Warp", isOn: Binding(
                    get: { setting.isWarpIntegrationOn },
                    set: { model.updateSetting(SettingPatch(isWarpIntegrationOn: $0)) }
                ))
                .help("Use local Warp activity to detect running work.")
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .tint(theme.color)
        .toggleStyle(ThemeCheckboxStyle(color: theme.color))
    }
}
