import SwiftUI
import LidCodeKit

/// One colour family for the whole panel.
///
/// The version this replaces used seven hues at once — green rings, a teal thermal step,
/// blue for a running timer, indigo in the power button, amber warnings, red floors, a
/// yellow unknown. Every one of them was individually defensible and together they made a
/// 340pt panel read as a dashboard: with everything coloured, colour stopped meaning
/// anything, and the eye had no idea where to land first.
///
/// So the panel now draws in a single orange, and the *only* thing colour encodes is
/// severity — how close a reading is to ending your hold. That is expressed as depth
/// within the family rather than a change of hue:
///
///   `brandSoft`  fine, or stale/idle — present but not asking for you
///   `brand`      the normal, live, working colour
///   `brandDeep`  danger: the thing that is about to stop the Mac
///
/// Danger deliberately stays legible. Flattening a 4% battery into the same orange as a
/// 90% one would be a prettier panel that fails at the one job it has, so the thresholds
/// below are unchanged from the multi-hue version — only the colours they return moved.
enum Palette {
    /// Claude orange, #D97757. The brand colour, and the panel's normal state.
    static let brand = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// The hot end of the same pigment. Reads as "worse" next to `brand` without leaving
    /// the family — which is what keeps a critical battery from disappearing into the
    /// decoration while still not introducing a second hue.
    static let brandDeep = Color(red: 0.76, green: 0.37, blue: 0.24)
    /// Muted brand: healthy, idle, or stale. Same colour, quieter, so a panel with nothing
    /// wrong is visually calm rather than blank.
    static let brandSoft = brand.opacity(0.55)
    /// The unfilled part of every bar. Deliberately `primary`, not the brand — a tinted
    /// track competes with its own fill and makes short bars unreadable.
    static let track = Color.primary.opacity(0.10)
    /// "No reading", which is not a severity and so must not be orange. Grey is hue-free,
    /// so it cannot be mistaken for a position on the scale above.
    static let unknown = Color.secondary.opacity(0.45)

    static func color(for state: HealthState) -> Color {
        switch state {
        case .ok:       return brandSoft
        case .degraded: return brand
        case .down:     return brandDeep
        case .unknown:  return unknown
        case .off:      return unknown
        }
    }

    static func color(for level: ThermalLevel) -> Color {
        switch level {
        case .nominal:  return brandSoft
        case .fair:     return brandSoft
        case .serious:  return brand
        case .critical: return brandDeep
        }
    }

    /// Rate-limit colour. Quiet up to 70%, brand to 90%, deep past it.
    ///
    /// Fixed thresholds rather than ones derived from a setting, because unlike the battery
    /// floors these are not ours to move: the ceiling is Anthropic's, and hitting it stops
    /// the work regardless of what this app thinks. The bands only say how much runway is
    /// left before that happens.
    static func usageColor(percent: Double) -> Color {
        if percent >= 90 { return brandDeep }
        if percent >= 70 { return brand }
        return brandSoft
    }

    /// Battery colour tracks the floors, not an arbitrary 20/50 split — the bar deepens
    /// exactly when the soft floor is the next thing that will happen.
    static func batteryColor(percent: Int?, setting soft: Int, hard: Int, isOnMain: Bool) -> Color {
        guard let percent else { return unknown }
        if isOnMain { return brandSoft }
        if percent <= hard { return brandDeep }
        if percent <= soft { return brand }
        return brandSoft
    }
}

/// A labelled horizontal bar: name, track, number. The panel's only gauge.
///
/// This replaced five radial rings. Rings look impressive and are the wrong shape for this
/// data: a ring needs ~62pt of height to say what a 6pt bar says, it forces the value into
/// a 44pt hole where a two-digit number is the *most* that fits (which is why the old
/// countdown quietly rescaled its own type), and a row of them reads as a car dashboard —
/// five equally loud circles, none of which is the thing you opened the panel for.
///
/// Bars stack, so four readings cost less vertical space than three rings did, and they
/// share a baseline grid: the fixed label and value columns mean every number in the panel
/// sits in the same place, which is what makes the set scannable in one pass instead of
/// four. Comparison between rows becomes free — the eye reads the fill edges as a column.
struct BarGauge: View {
    var label: String
    /// 0...1. Clamped here rather than trusted, because a NaN from a division upstream
    /// would otherwise crash layout rather than draw an empty bar.
    var fraction: Double
    var color: Color
    /// Already formatted, including its unit. Short — this column is two or three glyphs
    /// wide by design, and anything longer belongs in `.help`.
    var value: String

    /// Wide enough for "Battery" and "5-hour" at 10pt, and fixed so all four bars start at
    /// the same x. A self-sizing label would let a one-character change in one row shift
    /// the track of that row only, which destroys the column the layout is built on.
    private static let labelWidth: CGFloat = 52
    /// Fits "100%" with the digits monospaced. Trailing-aligned so the unit stays put as
    /// the number grows from one digit to three.
    private static let valueWidth: CGFloat = 40
    private static let barHeight: CGFloat = 6
    private static let corner: CGFloat = 3
    /// The row's height is fixed for the same reason everything else in this panel is: the
    /// window resizes itself to its content, so a row that grows by a point moves the whole
    /// panel under the pointer.
    private static let rowHeight: CGFloat = 14

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)

            // `GeometryReader` rather than a fraction-of-parent trick: the track has to be
            // whatever is left after two fixed columns, and that width is only knowable
            // here. It takes the offered width and is pinned to `barHeight` vertically, so
            // it cannot influence the row's height.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(Palette.track)
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(color)
                        // No minimum width. An empty bar means zero, and a 3pt sliver of
                        // colour at zero would be the gauge lying to keep itself visible.
                        .frame(width: geometry.size.width * clamped)
                }
            }
            .frame(height: Self.barHeight)

            Text(value)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
    }
}

/// Section label used across the panel.
struct SectionLabel: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
