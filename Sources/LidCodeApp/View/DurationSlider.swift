import AppKit
import SwiftUI

/// How long a hold runs, as a continuous track rather than a list of preset buttons.
///
/// The presets it replaces were `30m / 3h / 8h` — three buttons that between them could
/// not express "until I finish this build, about two hours". A menu of durations is the
/// wrong shape for a quantity: it makes the common case (something between the presets)
/// unreachable, and it makes the range itself invisible, so nobody could tell that 8h was
/// the ceiling until they went looking for a fourth button.
///
/// Snapped to 30 minutes, and the snap is the whole reason this feels like a control
/// rather than a slippery mess: a free slider over an 8-hour range puts ~28 seconds under
/// every pixel, so you cannot land on a round number and the readout never stops changing.
struct DurationSlider: View {
    /// The committed value, in seconds.
    var second: Int
    /// Called on release only — never mid-drag.
    ///
    /// Each commit writes `setting.json` and re-arms the live hold, and the panel resizes
    /// itself on every model change. Committing per frame meant ~60 disk writes and 60
    /// window re-layouts per drag, which is what a smooth-looking slider fighting a
    /// stuttering window looks like from the outside.
    var onCommit: (Int) -> Void

    static let minimumSecond = 30 * 60
    static let maximumSecond = 8 * 3600
    static let stepSecond = 30 * 60
    static var stepCount: Int { (maximumSecond - minimumSecond) / stepSecond }

    /// Where the knob actually is while a drag is in flight, 0...1, unsnapped.
    ///
    /// The knob tracks the pointer exactly and the *readout* snaps. Snapping the knob too
    /// makes it lurch away from the cursor by up to half a step, which reads as the
    /// control fighting you — the one thing a slider must never do.
    @State private var dragFraction: Double?
    /// The last step a tick was played for, so crossing a boundary fires exactly once.
    @State private var tickedStep: Int?

    private static let trackHeight: CGFloat = 30
    private static let knobInset: CGFloat = 3
    private var knobDiameter: CGFloat { Self.trackHeight - (Self.knobInset * 2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("KEEP AWAKE FOR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
                Spacer()
                Text(Self.display(second: displayedSecond))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(dragFraction == nil ? .secondary : .primary)
            }

            track

            HStack {
                Text("30m").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("8h").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(1, width - knobDiameter - (Self.knobInset * 2))
            let knobX = Self.knobInset + (travel * visualFraction)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))

                // Filled to the *centre* of the knob, not to its leading edge, so the fill
                // and the knob agree about where the value is at both ends of the travel.
                Capsule(style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.blue, Color.cyan],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: knobX + knobDiameter)

                tickRow(travel: travel)

                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
                    .overlay(
                        // Grip lines. Purely decorative, and the only reason the knob does
                        // not read as a blank dot at this size.
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { _ in
                                Capsule().fill(Color.black.opacity(0.22)).frame(width: 1.2, height: 8)
                            }
                        }
                    )
                    .offset(x: knobX)
            }
            .frame(height: Self.trackHeight)
            .contentShape(Rectangle())
            // `minimumDistance: 0` so a plain click anywhere on the track jumps there,
            // which is what every native slider does and what people try first.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = (value.location.x - Self.knobInset - (knobDiameter / 2)) / travel
                        let clamped = min(1, max(0, raw))
                        dragFraction = clamped
                        tick(for: Self.step(forFraction: clamped))
                    }
                    .onEnded { _ in
                        let committed = Self.second(forFraction: dragFraction ?? visualFraction)
                        dragFraction = nil
                        tickedStep = nil
                        if committed != second { onCommit(committed) }
                    }
            )
        }
        .frame(height: Self.trackHeight)
    }

    private func tickRow(travel: CGFloat) -> some View {
        // Every step is a dot, so the granularity is visible before you touch anything —
        // you can see that it lands on halves rather than discovering it by dragging.
        ForEach(1..<Self.stepCount, id: \.self) { index in
            let fraction = Double(index) / Double(Self.stepCount)
            Circle()
                .fill(Color.primary.opacity(fraction <= visualFraction ? 0.28 : 0.14))
                .frame(width: 2, height: 2)
                .offset(x: Self.knobInset + (knobDiameter / 2) + (travel * fraction) - 1)
        }
    }

    // MARK: - Value mapping

    /// Where the knob is drawn: the raw pointer position mid-drag, the committed value
    /// otherwise.
    private var visualFraction: Double {
        dragFraction ?? Self.fraction(forSecond: second)
    }

    /// What the readout says: always a snapped value, dragging or not.
    private var displayedSecond: Int {
        dragFraction.map(Self.second(forFraction:)) ?? Self.clamped(second)
    }

    static func clamped(_ second: Int) -> Int {
        min(maximumSecond, max(minimumSecond, second))
    }

    static func fraction(forSecond second: Int) -> Double {
        Double(clamped(second) - minimumSecond) / Double(maximumSecond - minimumSecond)
    }

    static func step(forFraction fraction: Double) -> Int {
        Int((fraction * Double(stepCount)).rounded())
    }

    static func second(forFraction fraction: Double) -> Int {
        minimumSecond + (step(forFraction: fraction) * stepSecond)
    }

    /// "30m", "2h", "4h 30m". No zero-padding and no bare "0m" — this is a duration you
    /// chose, not a countdown, so it should read the way you would say it out loud.
    static func display(second: Int) -> String {
        let value = clamped(second)
        let hour = value / 3600
        let minute = (value % 3600) / 60
        if hour == 0 { return "\(minute)m" }
        return minute == 0 ? "\(hour)h" : "\(hour)h \(minute)m"
    }

    /// The trackpad's own detent click, borrowed.
    ///
    /// `.alignment` is the feedback macOS plays when a dragged object snaps to a guide,
    /// which is exactly what is happening here — so the slider feels like the rest of the
    /// system rather than like something with a custom buzz. Silently does nothing on
    /// hardware without a Force Touch trackpad.
    private func tick(for step: Int) {
        guard tickedStep != step else { return }
        tickedStep = step
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
