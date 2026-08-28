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
struct PowerButton: View {
    var isEnabled: Bool
    var isSwitching: Bool
    var isProtected: Bool
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

                // A pill rather than a checkmark. The button's own fill already says on or
                // off at a glance; this says it again in words for the case the colour
                // cannot cover — a screenshot, a colour-blind reader, or the half second
                // after a click when you are checking that it took.
                Text(isEnabled ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isEnabled ? Color.white.opacity(0.24)
                                                 : Color.primary.opacity(0.09))
                    )
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    // One gradient for every on state, not two.
                    //
                    // The button used to fill green-to-teal for a plain hold and
                    // blue-to-indigo for a protected one, which made the *most* important
                    // control on the panel change hue based on the least important
                    // distinction it draws. The state that actually matters is on versus
                    // off, and that is now the whole colour story: brand orange, or grey.
                    .fill(isEnabled
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Palette.brand, Palette.brandDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.primary.opacity(0.07)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        // The paragraph the caption used to print, where it costs nothing: hover text is
        // free vertical space, and it is read by exactly the person who wants it.
        .help(helpText)
    }

    /// State first, consequence second — `ON · lid can close`.
    ///
    /// A button labelled with its action ("Disable") and a button labelled with its state
    /// ("Keep Mac Awake") are opposites, and picking the wrong one is how toggles end up
    /// meaning the reverse of what people read. Leading with ON/OFF settles it, and the
    /// clause after the dot is the one thing the state does not tell you on its own:
    /// whether the hold survives the lid closing.
    private var line: String {
        if !isEnabled { return "OFF" }
        return isProtected ? "ON · lid can close" : "ON · lid must stay open"
    }

    private var symbolName: String {
        if !isEnabled { return "moon.fill" }
        return isProtected ? "laptopcomputer.slash" : "bolt.fill"
    }

    private var helpText: String {
        if isSwitching { return "Asking the root helper…" }
        if !isEnabled { return "Hold your Mac awake, and keep it awake with the lid shut." }
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
                    Circle()
                        .fill(isOn ? Palette.brandSoft : Palette.brandDeep)
                        .frame(width: 5, height: 5)
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
