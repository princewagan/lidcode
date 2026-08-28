import AppKit
import SwiftUI

/// How long a hold runs, as a continuous track rather than a list of preset buttons.
///
/// Snapped to 30 minutes, with a maximum of 6 hours (J6) so the intervals are well-spaced.
///
/// J3 fix — smooth drag: the previous implementation committed the drag value to the model
/// on every `onChanged` call. The model persisted it and republished on the 5-second tick,
/// which snapped the knob back mid-drag. The fix: a `@State dragFraction` owns the knob
/// position during drag and the model is only updated on `onEnded`. Inbound model changes
/// are ignored while `isDragging` is true.
struct DurationSlider: View {
    /// The committed value, in seconds. Read from the model; updated only on drag end.
    var second: Int
    /// Called on release only — never mid-drag (J3: no per-frame disk writes or model updates).
    var onCommit: (Int) -> Void

    static let minimumSecond = 30 * 60
    /// Max is 6h (J6), down from 8h, so the 30-minute steps are more spaced.
    static let maximumSecond = 6 * 3600
    static let stepSecond = 30 * 60
    static var stepCount: Int { (maximumSecond - minimumSecond) / stepSecond }

    /// Where the knob actually is while a drag is in flight, 0...1, unsnapped.
    ///
    /// J3: This local state owns the thumb position during drag. It is set on
    /// `onChanged` and cleared on `onEnded`. While non-nil, inbound `second` changes
    /// from the model are ignored — so the 5-second tick cannot snap the thumb back.
    @State private var dragFraction: Double?
    /// True while a drag gesture is in flight, used to gate model-value reads.
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
        // Disable animations on the slider itself — the knob tracks the pointer directly
        // and any SwiftUI animation layered on top fights the gesture recogniser.
        .transaction { $0.animation = nil }
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
                    .fill(LinearGradient(
                        colors: [Palette.brand, Palette.brandDeep],
                        startPoint: .leading,
                        endPoint: .trailing))
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
            .frame(height: Self.trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = (value.location.x - Self.knobInset - (knobDiameter / 2)) / travel
                        let clamped = min(1, max(0, raw))
                        // J3: local drag state owns the thumb — model not touched here
                        isDragging = true
                        dragFraction = clamped
                        tick(for: Self.step(forFraction: clamped))
                    }
                    .onEnded { _ in
                        // J3: commit to model only on drag end
                        let committed = Self.second(forFraction: dragFraction ?? visualFraction)
                        isDragging = false
                        dragFraction = nil
                        tickedStep = nil
                        if committed != second { onCommit(committed) }
                    }
            )
        }
        .frame(height: Self.trackHeight)
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

    /// Where the knob is drawn: the raw pointer position mid-drag, the committed value
    /// otherwise. J3: while dragging, ignore inbound model updates (dragFraction wins).
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
