import SwiftUI
import LidCodeKit

/// The one control the panel exists for.
///
/// This replaced a three-way selector — Sleep / Awake / Lid shut. Three modes was one
/// more question than anyone opening a menu-bar app at midnight wants to answer, and two
/// of the three answers were the same answer: "Awake" and "Lid shut" both mean *keep
/// working*, and they differed only in whether the protection survived the lid closing —
/// which is not a preference, it is just the better of the two. So the selector offered a
/// choice nobody had a reason to make, and hid the one they did.
///
/// Now it is a switch. On means closed-lid protection when the root helper is there and a
/// plain hold when it is not, which is the strongest thing available in both cases.
///
/// It is also down to one line of text, from three. The button used to carry a title
/// ("Keep Mac Awake"), a caption ("Protected — survives the lid closing") and the pill,
/// which is three statements of the same fact stacked vertically inside a control whose
/// entire job is to be unambiguous at a glance. `ON · lid can close` is all three at once,
/// and the sentence-length version moved to the tooltip.
/// The F1-F4 button cycle: BLOCKED → OVERRIDE → DISABLED → (back to BLOCKED or normal).
///
/// When a guard (thermal/battery) is blocking, the button enters the BLOCKED state:
/// it renders faded/desaturated to signal "enabled but held back". Pressing cycles:
///   1. BLOCKED (faded) → press → OVERRIDE (full colour, guard bypassed)
///   2. OVERRIDE → press → DISABLED (off)
///   3. DISABLED → press → back to BLOCKED (guard still present)
/// Warning texts are independent — they always reflect real hardware, not button state.
struct PowerButton: View {
    var isEnabled: Bool
    var isSwitching: Bool
    var isProtected: Bool
    /// True when a guard is blocking and the user has NOT yet overridden it (state 1).
    var isGuardBlocked: Bool = false
    /// True when the user has explicitly overridden the guard (state 2).
    var isGuardOverride: Bool = false
    var onToggle: (Bool) -> Void

    var body: some View {
        Button {
            onToggle(!isEnabled)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if isSwitching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isEnabled ? .white : .secondary)
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                // Fixed, because a spinner and an SF Symbol do not measure alike and the
                // swap happens mid-click — the one moment the button must not move.
                .frame(width: 22, height: 22)

                Text(line)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                // The pill says the current state in words. In BLOCKED state it says "BLOCKED"
                // so the user instantly reads "enabled but held back" rather than "on".
                Text(pillLabel)
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(pillBackground)
                    )
            }
            .foregroundStyle(labelStyle)
            .opacity(isGuardBlocked ? 0.55 : 1.0)  // F1: faded when blocked
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(buttonBackground)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isGuardBlocked)
            .animation(.easeOut(duration: 0.15), value: isGuardOverride)
            .animation(.easeOut(duration: 0.15), value: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .help(helpText)
    }

    private var line: String {
        if !isEnabled { return "OFF" }
        if isGuardBlocked { return "ON · guard blocking" }
        if isGuardOverride { return "ON · guard overridden" }
        return isProtected ? "ON · lid can close" : "ON · lid must stay open"
    }

    private var pillLabel: String {
        if !isEnabled { return "OFF" }
        if isGuardBlocked { return "BLOCKED" }
        if isGuardOverride { return "OVERRIDE" }
        return "ON"
    }

    private var symbolName: String {
        if !isEnabled { return "moon.fill" }
        if isGuardBlocked { return "exclamationmark.shield" }
        if isGuardOverride { return "bolt.shield.fill" }
        return isProtected ? "laptopcomputer.slash" : "bolt.fill"
    }

    private var labelStyle: AnyShapeStyle {
        if isEnabled {
            return AnyShapeStyle(.white)
        }
        return AnyShapeStyle(.secondary)
    }

    private var pillBackground: AnyShapeStyle {
        if isGuardBlocked { return AnyShapeStyle(Palette.brandDeep.opacity(0.4)) }
        if isGuardOverride { return AnyShapeStyle(Color.white.opacity(0.28)) }
        if isEnabled { return AnyShapeStyle(Color.white.opacity(0.24)) }
        return AnyShapeStyle(Color.primary.opacity(0.09))
    }

    private var buttonBackground: AnyShapeStyle {
        if !isEnabled {
            return AnyShapeStyle(Color.primary.opacity(0.07))
        }
        if isGuardBlocked {
            // Desaturated/faded gradient — guard is blocking (F1)
            return AnyShapeStyle(LinearGradient(
                colors: [Palette.brand.opacity(0.5), Palette.brandDeep.opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        }
        // Normal ON or OVERRIDE — full colour (F2)
        return AnyShapeStyle(LinearGradient(
            colors: [Palette.brand, Palette.brandDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing))
    }

    private var helpText: String {
        if isSwitching { return "Asking the root helper…" }
        if !isEnabled { return "Hold your Mac awake, and keep it awake with the lid shut." }
        if isGuardBlocked { return "A thermal or battery guard is blocking the hold. Press to override the guard and continue anyway." }
        if isGuardOverride { return "Guard is overridden — hold continues despite the warning. Press to disable the hold entirely." }
        return isProtected
            ? "Holding your Mac awake. Closed-lid protection is active, so the hold survives shutting the lid. Click to stop."
            : "Holding your Mac awake, but the root helper is not installed — closing the lid will still sleep it. Click to stop."
    }
}

/// The two safety rules the user is allowed to waive.
///
/// These replaced a popup banner that appeared only *after* the governor had already
/// stopped the Mac. That timing is backwards: the moment you want to say "ignore the
/// battery tonight" is before you walk away, and the banner was unreachable then — it
/// only existed once the run was already dead, which is exactly too late to save it.
///
/// They now live inside the settings disclosure rather than under the switch. Same one
/// click before the run, but they no longer print "Disable on 15m hot temperature" across
/// the top of a panel you opened to read a battery level.
///
/// Labels are short and the consequence is in the tooltip, with one exception: the *off*
/// state has to name what is now unguarded, because two waivable rules that both read
/// "Override" is a state you cannot recover from without clicking one to find out.
struct GuardToggle: View {
    var isOn: Bool
    var onLabel: String
    var offLabel: String
    var symbolName: String
    var detail: String
    var onToggle: (Bool) -> Void

    var body: some View {
        Button {
            onToggle(!isOn)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: isOn ? symbolName : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        // Waived is the deeper orange: a guard you have turned off is the
                        // condition most likely to end the run, so it sits at the danger
                        // end of the family rather than switching hue to say so.
                        .foregroundStyle(isOn ? Palette.brandSoft : Palette.brandDeep)
                    Spacer(minLength: 0)
                    // The word, not a coloured dot.
                    //
                    // A 5-point circle that changed shade was the only thing distinguishing
                    // "this rule is protecting you" from "this rule is switched off", and
                    // the two orange shades read as the same colour at a glance. The result
                    // was a guard people believed was on, doing nothing — reported as the
                    // guard not working, which from the outside is indistinguishable.
                    Text(isOn ? "ON" : "OFF")
                        .font(.system(size: 8, weight: .bold))
                        .kerning(0.4)
                        .foregroundStyle(isOn ? Color.primary.opacity(0.65) : Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isOn
                                           ? Color.primary.opacity(0.10)
                                           : Palette.brandDeep))
                }
                Text(isOn ? onLabel : offLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // One line held open, not two. The labels are short enough now that
                    // neither state wraps — but the height stays fixed anyway, because the
                    // two strings are different lengths and letting the row size itself is
                    // what moved the whole panel every time either was clicked.
                    .frame(height: 13, alignment: .topLeading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? Color.primary.opacity(0.06) : Palette.brandDeep.opacity(0.13))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detail)
    }
}
