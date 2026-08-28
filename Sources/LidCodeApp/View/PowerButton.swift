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
                    Circle()
                        .fill(Color.white.opacity(isEnabled ? 0.22 : 0.0))
                        .frame(width: 26, height: 26)
                    if isSwitching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isEnabled ? .white : .secondary)
                    } else {
                        Image(systemName: symbolName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 9))
                        .opacity(isEnabled ? 0.85 : 0.7)
                        .lineLimit(1)
                }

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
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isEnabled
                          ? AnyShapeStyle(LinearGradient(
                                colors: isProtected ? [.blue, .indigo] : [.green, .teal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.primary.opacity(0.07)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .help(isEnabled
              ? "Stop holding your Mac awake and let it sleep normally."
              : "Hold your Mac awake, and keep it awake with the lid shut.")
    }

    /// "Keep Mac Awake" is what it *is doing*, not what clicking will do.
    ///
    /// A button labelled with its action ("Disable") and a button labelled with its state
    /// ("Keep Mac Awake") are opposites, and picking the wrong one is how toggles end up
    /// meaning the reverse of what people read. The ON/OFF pill settles it: the row as a
    /// whole reads "Keep Mac Awake — ON", which cannot be parsed backwards.
    private var title: String {
        isEnabled ? "Keep Mac Awake" : "Disabled"
    }

    private var caption: String {
        if isSwitching { return "Asking the helper…" }
        if !isEnabled { return "Your Mac sleeps normally" }
        return isProtected ? "Protected — survives the lid closing" : "Awake, but not past a lid close"
    }

    private var symbolName: String {
        if !isEnabled { return "moon.fill" }
        return isProtected ? "laptopcomputer.slash" : "bolt.fill"
    }
}

/// The two safety rules the user is allowed to waive, side by side and always visible.
///
/// These replaced a popup banner that appeared only *after* the governor had already
/// stopped the Mac. That timing is backwards: the moment you want to say "ignore the
/// battery tonight" is before you walk away, and the banner was unreachable then — it
/// only existed once the run was already dead, which is exactly too late to save it.
///
/// Each button carries its own consequence in its label rather than a generic "Override",
/// so the off state names what is now unguarded instead of leaving you to remember which
/// of two overrides you left on.
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
                        .foregroundStyle(isOn ? Color.green : Color.orange)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(isOn ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                }
                Text(isOn ? onLabel : offLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Two lines held open whether or not both are used. "Disable on 15m hot
                    // temperature" wraps and "Override temperature" does not, so letting
                    // this size itself moved the whole panel every time either was clicked.
                    .frame(height: 26, alignment: .topLeading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? Color.primary.opacity(0.06) : Color.orange.opacity(0.13))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detail)
    }
}
