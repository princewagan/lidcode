import AppKit
import SwiftUI

/// How long a hold runs, as a continuous track rather than a list of preset buttons.
///
/// Snapped to 30 minutes, with a maximum of 6 hours (J6) so the intervals are well-spaced.
///
/// # Why the knob used to jump, and what each fix addresses
///
/// Three separate defects stacked into one "glitchy" feel, and each needed its own fix.
///
/// **1. Teleport on grab.** The gesture mapped `value.location.x` straight to a fraction,
/// so the instant you pressed the knob it re-centred itself under the pointer. Pressing
/// two points left of centre moved the knob two points left before you had dragged at
/// all. `grabOffset` records the distance between the pointer and the knob centre on the
/// first event and subtracts it for the rest of the drag, so a grab is a grab. A press on
/// bare track still jumps — that is a deliberate exception, because a click on a track is
/// a request to go *there*.
///
/// **2. Flicker back, then forward, on release.** `onEnded` cleared the local drag state
/// in the same frame it called `onCommit`. The commit is asynchronous (it goes through
/// the runtime queue), so for one or more frames `second` was still the *old* value and
/// the knob drew itself back at the old position before the new one arrived. That is the
/// "flicker to the original spot and then to the new spot" exactly. `pendingSecond` now
/// keeps the knob at the committed position until the model reports the value back.
///
/// **3. Repaint fighting the drag.** The panel re-measures and re-frames itself on every
/// model publish, which is every five seconds. `onInteracting` lets the panel stand still
/// while a drag is in flight.
///
/// The knob tracks the pointer 1:1 during a drag with no animation. Everything else — a
/// release settling onto its step, a value changed from elsewhere — eases over 0.14s.
struct DurationSlider: View {
    /// The committed value, in seconds. Read from the model; updated only on drag end.
    var second: Int
    /// Called on release only — never mid-drag (no per-frame disk writes or model updates).
    var onCommit: (Int) -> Void
    /// Raised while a drag is in flight so the containing panel can stop re-laying itself
    /// out underneath the pointer. Optional so the view stays usable on its own.
    var onInteracting: (Bool) -> Void = { _ in }

    static let minimumSecond = 30 * 60
    /// Max is 6h (J6), down from 8h, so the 30-minute steps are more spaced.
    static let maximumSecond = 6 * 3600
    static let stepSecond = 30 * 60
    static var stepCount: Int { (maximumSecond - minimumSecond) / stepSecond }

    /// Where the knob is drawn, 0...1, when it is not simply following `second`.
    ///
    /// Non-nil in two situations: during a drag, where it is the live pointer position,
    /// and between a release and the model echoing the committed value back, where it is
    /// the committed position. Both are cases where `second` is the wrong thing to draw.
    @State private var dragFraction: Double?
    /// The value handed to `onCommit` that the model has not confirmed yet. See fix 2.
    @State private var pendingSecond: Int?
    /// Pointer-minus-knob-centre at the moment the drag started. See fix 1.
    @State private var grabOffset: CGFloat?
    /// True while a drag gesture is in flight. Gates animation and the panel resize.
    @State private var isDragging = false
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
                    // Fixed width so the readout never causes the label row to reflow
                    .frame(minWidth: 44, alignment: .trailing)
                    .foregroundStyle(isDragging ? Color.primary : Color.secondary)
            }

            track

            HStack {
                Text("30m").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("6h").font(.system(size: 9)).foregroundStyle(.tertiary)
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

                // Filled to the centre of the knob.
                Capsule(style: .continuous)
                    .fill(Palette.brand)
                    .frame(width: knobX + knobDiameter)

                tickRow(travel: travel)

                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
                    .overlay(
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { _ in
                                Capsule().fill(Color.black.opacity(0.22)).frame(width: 1.2, height: 8)
                            }
                        }
                    )
                    .offset(x: knobX)
            }
            // 1:1 with the pointer while dragging — any animation there lags the finger and
            // reads as rubber-banding. Everything else eases, so a release settling onto
            // its step and a value changed from the CLI both glide instead of snapping.
            .animation(isDragging ? nil : .easeOut(duration: 0.14), value: visualFraction)
            .frame(height: Self.trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let knobCentre = Self.knobInset + (knobDiameter / 2) + (travel * visualFraction)
                        if grabOffset == nil {
                            // First event of this gesture. If the press landed on the knob,
                            // remember how far off centre it was and preserve that for the
                            // whole drag. If it landed on bare track, treat it as "go here".
                            let delta = value.startLocation.x - knobCentre
                            // A few points of slack past the knob edge, so a press that
                            // just misses still counts as a grab rather than a jump.
                            let grabRadius: CGFloat = (knobDiameter / 2) + 4
                            grabOffset = abs(delta) <= grabRadius ? delta : 0
                            isDragging = true
                            onInteracting(true)
                        }
                        let target = value.location.x - (grabOffset ?? 0)
                        let raw = (target - Self.knobInset - (knobDiameter / 2)) / travel
                        let clamped = min(1, max(0, raw))
                        // Local drag state owns the thumb — the model is not touched here.
                        dragFraction = clamped
                        tick(for: Self.step(forFraction: clamped))
                    }
                    .onEnded { _ in
                        let committed = Self.second(forFraction: dragFraction ?? visualFraction)
                        isDragging = false
                        grabOffset = nil
                        tickedStep = nil
                        onInteracting(false)

                        if committed == second {
                            // Nothing to commit, so nothing will echo back. Release the
                            // knob to the model straight away or it would sit on the
                            // local fraction forever.
                            withAnimation(.easeOut(duration: 0.14)) { dragFraction = nil }
                            pendingSecond = nil
                            return
                        }
                        // Hold the knob at the committed position — snapped to its step,
                        // eased so the last few points of travel are not a jump — until
                        // the model reports the new value back. See fix 2.
                        pendingSecond = committed
                        withAnimation(.easeOut(duration: 0.14)) {
                            dragFraction = Self.fraction(forSecond: committed)
                        }
                        onCommit(committed)
                    }
            )
        }
        .frame(height: Self.trackHeight)
        // The model has caught up (or moved somewhere else entirely). Either way the
        // local override has done its job and `second` is the truth again.
        .onChange(of: second) { _, _ in
            guard !isDragging else { return }
            pendingSecond = nil
            dragFraction = nil
        }
    }

    private func tickRow(travel: CGFloat) -> some View {
        ForEach(1..<Self.stepCount, id: \.self) { index in
            let fraction = Double(index) / Double(Self.stepCount)
            Circle()
                .fill(Color.primary.opacity(fraction <= visualFraction ? 0.28 : 0.14))
                .frame(width: 2, height: 2)
                .offset(x: Self.knobInset + (knobDiameter / 2) + (travel * fraction) - 1)
        }
    }

    // MARK: - Value mapping

    /// Where the knob is drawn: the local override when there is one, the committed
    /// value otherwise.
    private var visualFraction: Double {
        dragFraction ?? Self.fraction(forSecond: second)
    }

    /// What the readout says: always a snapped value, dragging or not.
    private var displayedSecond: Int {
        if let pendingSecond, !isDragging { return pendingSecond }
        return dragFraction.map(Self.second(forFraction:)) ?? Self.clamped(second)
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

    /// "30m", "2h", "4h 30m". No zero-padding and no bare "0m".
    static func display(second: Int) -> String {
        let value = clamped(second)
        let hour = value / 3600
        let minute = (value % 3600) / 60
        if hour == 0 { return "\(minute)m" }
        return minute == 0 ? "\(hour)h" : "\(hour)h \(minute)m"
    }

    /// The trackpad's own detent click, borrowed.
    private func tick(for step: Int) {
        guard tickedStep != step else { return }
        tickedStep = step
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
