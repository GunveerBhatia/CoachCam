import UIKit

/// Runs the step-by-step walkthrough for the active suggestion, without flicker.
///
/// - Every check value is smoothed (moving average) before it's judged.
/// - A step completes when the smoothed value stays inside its TIGHT band for `hold` seconds
///   (~0.4 s) → ✓, one light haptic, next step. Then it is LATCHED.
/// - A latched step only comes back if the value stays outside its WIDE band for
///   `undoSeconds` (~1 s). Small drift never re-shows it (this fixes the 45° loop).
/// - All steps latched → `allDone` ("Take it"). It stays done unless a step really comes undone.
/// - At most `maxSteps` (4) steps per shot. Skip a step, or swipe back to revisit one.
final class StepGuide: ObservableObject {
    struct Display: Equatable {
        var text: String
        var arrow: ArrowType
        var index: Int
        var isManual: Bool
    }

    enum DotState: Equatable { case done, skipped, current, todo }

    @Published private(set) var display: Display?
    @Published private(set) var dots: [DotState] = []
    @Published private(set) var allDone = false
    /// Briefly true right after a step completes (shows the ✓).
    @Published private(set) var justCompleted = false
    /// Live numbers for the current step (debug overlay).
    @Published private(set) var debugText = "—"

    private let config = AppConfig.shared.guide
    private var suggestionID: String?
    private var steps: [GuideStep] = []
    private var states: [StepState] = []
    private var forcedIndex: Int?

    private struct StepState {
        var smoothed: Double?
        var insideSince: TimeInterval?
        var outsideSince: TimeInterval?
        var latched = false
        var skipped = false
    }

    /// Starts (or restarts) the walkthrough for a suggestion; nil stops it.
    func start(_ suggestion: Playbook.Suggestion?) {
        suggestionID = suggestion?.id
        let all = suggestion.map { Playbook.shared.steps(for: $0) } ?? []
        steps = Array(all.prefix(config.maxSteps))
        states = steps.map { _ in StepState() }
        forcedIndex = nil
        allDone = false
        display = nil
        dots = []
        if let suggestion { Log.info("Guide: \(suggestion.id), \(steps.count) steps") }
    }

    var isRunning: Bool { suggestionID != nil }

    /// Called after each analysis while guiding.
    func update(context: StepContext) {
        guard !steps.isEmpty else {
            if suggestionID != nil && !allDone { allDone = true }   // A shot with no steps is ready at once.
            return
        }
        let now = CACurrentMediaTime()
        var measurements: [StepMeasurement] = []

        for i in steps.indices {
            let step = steps[i]
            let m = StepEvaluator.measure(step.check, context, angleMargin: config.undoMinMargin)
            measurements.append(m)
            if m.isManual || states[i].skipped { continue }

            // Smooth (moving average). Unmeasurable → keep the last value but don't advance.
            if let v = m.value {
                states[i].smoothed = states[i].smoothed.map { $0 * (1 - config.smoothing) + v * config.smoothing } ?? v
            }
            guard let value = states[i].smoothed, m.value != nil || states[i].latched else {
                states[i].insideSince = nil
                continue
            }

            let (wideLow, wideHigh) = wideBand(step.check, m)
            let insideTight = value >= m.low && value <= m.high
            let outsideWide = value < wideLow || value > wideHigh

            if !states[i].latched {
                if insideTight {
                    if states[i].insideSince == nil { states[i].insideSince = now }
                    if let since = states[i].insideSince, now - since >= (step.hold ?? config.holdSeconds) {
                        states[i].latched = true
                        states[i].outsideSince = nil
                        if i == currentIndex() || forcedIndex == i { celebrate() }
                        if forcedIndex == i { forcedIndex = nil }
                    }
                } else {
                    states[i].insideSince = nil
                }
            } else {
                // Latched: only undo after clearly leaving the wide band for a while.
                if outsideWide {
                    if states[i].outsideSince == nil { states[i].outsideSince = now }
                    if let since = states[i].outsideSince, now - since >= (step.check.undoSeconds ?? config.undoSeconds) {
                        states[i].latched = false
                        states[i].insideSince = nil
                        Log.info("Step \(step.id) undone (\(format(value, m)) outside \(format(wideLow, m))…\(format(wideHigh, m)))")
                    }
                } else {
                    states[i].outsideSince = nil
                }
            }
        }

        let index = currentIndex()
        let finished = index == nil
        if finished && !allDone {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Log.info("All steps done: Take it")
        }
        if finished != allDone { allDone = finished }

        if let i = index {
            let step = steps[i]
            let m = measurements[i]
            var chosen: ArrowType? = step.arrow
            if step.arrow == .auto, let v = states[i].smoothed {
                chosen = v < m.low ? m.lowArrow : (v > m.high ? m.highArrow : nil)
            } else if step.arrow == .auto {
                chosen = nil
            }
            let newDisplay = Display(text: step.text(for: chosen), arrow: chosen ?? ArrowType.none, index: i,
                                     isManual: m.isManual)
            if newDisplay != display { display = newDisplay }
            debugText = liveText(i, m)
        } else {
            if display != nil { display = nil }
            debugText = "all \(steps.count) steps latched"
        }

        let newDots: [DotState] = steps.indices.map { i in
            if i == index { return .current }
            if states[i].latched { return .done }
            if states[i].skipped { return .skipped }
            return .todo
        }
        if newDots != dots { dots = newDots }
    }

    // MARK: - Your controls

    func skip() {
        guard let i = currentIndex() else { return }
        states[i].skipped = true
        if forcedIndex == i { forcedIndex = nil }
        Log.info("Skipped step \(steps[i].id)")
    }

    /// Swipe back: revisit the previous step.
    func back() {
        let current = currentIndex() ?? steps.count
        guard current > 0 else { return }
        let previous = current - 1
        states[previous] = StepState()
        forcedIndex = previous
    }

    /// For steps only you can confirm ("Eyes on the lens"): tap ✓.
    func confirmManual() {
        guard let i = currentIndex() else { return }
        states[i].latched = true
        celebrate()
    }

    // MARK: - Internals

    /// The wide band: the playbook's undoMin/undoMax, or the tight band widened.
    private func wideBand(_ check: StepCheck, _ m: StepMeasurement) -> (Double, Double) {
        // One-sided bands (e.g. "head in frame": only a minimum) use the margin alone.
        let bounded = abs(m.low) < 1e12 && abs(m.high) < 1e12
        let width = bounded ? m.high - m.low : 0
        let widen = max(width * config.undoWiden, m.minMargin)
        let low = check.undoMin ?? (abs(m.low) < 1e12 ? m.low - widen : m.low)
        let high = check.undoMax ?? (abs(m.high) < 1e12 ? m.high + widen : m.high)
        return (low, high)
    }

    private func currentIndex() -> Int? {
        if let forced = forcedIndex, forced < steps.count, !states[forced].latched { return forced }
        return states.indices.first { !states[$0].latched && !states[$0].skipped }
    }

    private func celebrate() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justCompleted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + config.checkMarkSeconds) { self.justCompleted = false }
    }

    private func format(_ v: Double, _ m: StepMeasurement) -> String {
        if abs(v) > 1e12 { return v > 0 ? "∞" : "-∞" }
        return m.unit == "°" ? String(format: "%.1f°", v) : String(format: "%.3f", v)
    }

    /// e.g. "2/4 fortyFive: 41.2° (raw 43.0°) done 37.0°…53.0° · undo 30.0°…60.0° · hold 0.2/0.4s"
    private func liveText(_ i: Int, _ m: StepMeasurement) -> String {
        let step = steps[i]
        if m.isManual { return "\(i + 1)/\(steps.count) \(step.id): tap ✓" }
        guard let smoothed = states[i].smoothed else { return "\(i + 1)/\(steps.count) \(step.id): no reading" }
        let (wl, wh) = wideBand(step.check, m)
        let raw = m.value.map { format($0, m) } ?? "—"
        var hold = ""
        if let since = states[i].insideSince {
            hold = String(format: " · hold %.1f/%.1fs", CACurrentMediaTime() - since, step.hold ?? config.holdSeconds)
        }
        return "\(i + 1)/\(steps.count) \(step.id): \(format(smoothed, m)) (raw \(raw)) done \(format(m.low, m))…\(format(m.high, m)) · undo \(format(wl, m))…\(format(wh, m))\(hold)"
    }
}
