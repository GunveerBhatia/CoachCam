import UIKit

/// Runs the step-by-step walkthrough for the current playbook rule.
///
/// - One step at a time; a step is done when its check has passed for `hold` seconds
///   (~0.4 s) → a quick ✓, one light haptic, next step.
/// - If a finished step comes undone for a moment (you drift off level), it quietly
///   becomes the current step again.
/// - Skip a step you don't care about; swipe back to revisit the previous one.
/// - All steps done → "Take it", green shutter, one success haptic (not repeated).
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
    /// Which step the debug overlay should explain, and its measured value.
    @Published private(set) var debugText = "—"

    private let config = AppConfig.shared.guide
    private var ruleID: String?
    private var steps: [GuideStep] = []
    private var states: [State] = []
    private var forcedIndex: Int?

    private struct State {
        var passingSince: TimeInterval?
        var failingSince: TimeInterval?
        var completed = false
        var skipped = false
        var manualDone = false
    }

    /// Called after each analysis with the rule in use.
    func update(rule: Playbook.Rule?, context: StepContext) {
        let now = CACurrentMediaTime()
        if rule?.id != ruleID { load(rule) }
        guard !steps.isEmpty else {
            if display != nil { display = nil; dots = []; allDone = false }
            return
        }

        var results: [StepResult] = []
        for i in steps.indices {
            var result = StepEvaluator.evaluate(steps[i].check, context)
            if states[i].manualDone { result.status = .pass }
            results.append(result)
            let hold = steps[i].hold ?? config.holdSeconds
            switch result.status {
            case .pass:
                states[i].failingSince = nil
                if states[i].passingSince == nil { states[i].passingSince = now }
                if !states[i].completed, let since = states[i].passingSince, now - since >= hold {
                    states[i].completed = true
                    if i == currentIndex() { celebrateStep() }
                    if forcedIndex == i { forcedIndex = nil }
                }
            case .fail, .unknown:
                states[i].passingSince = nil
                if states[i].completed {
                    if states[i].failingSince == nil { states[i].failingSince = now }
                    if let since = states[i].failingSince, now - since >= config.undoGraceSeconds {
                        states[i].completed = false   // Quietly go back to it.
                    }
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
            let chosen: ArrowType? = step.arrow == .auto ? results[i].arrow : step.arrow
            let arrow: ArrowType = chosen ?? ArrowType.none
            let newDisplay = Display(text: step.text(for: chosen),
                                     arrow: arrow, index: i, isManual: step.check.type == "manual")
            if newDisplay != display { display = newDisplay }
            debugText = "\(i + 1)/\(steps.count) \(step.id): \(results[i].detail)"
        } else {
            if display != nil { display = nil }
            debugText = "all done"
        }

        let newDots: [DotState] = steps.indices.map { i in
            if i == index { return .current }
            if states[i].completed { return .done }
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
        states[previous].skipped = false
        states[previous].completed = false
        states[previous].manualDone = false
        states[previous].passingSince = nil
        forcedIndex = previous
    }

    /// For steps only you can confirm ("Eyes on the lens"): tap ✓.
    func confirmManual() {
        guard let i = currentIndex() else { return }
        states[i].manualDone = true
    }

    // MARK: - Internals

    private func load(_ rule: Playbook.Rule?) {
        ruleID = rule?.id
        steps = rule.map { Playbook.shared.steps(for: $0) } ?? []
        states = steps.map { _ in State() }
        forcedIndex = nil
        allDone = false
        if let rule { Log.info("Guide: \(rule.id) with \(steps.count) steps") }
    }

    /// First step that isn't done or skipped (or the one you swiped back to).
    private func currentIndex() -> Int? {
        if let forced = forcedIndex, forced < steps.count, !states[forced].completed { return forced }
        return states.indices.first { !states[$0].completed && !states[$0].skipped }
    }

    private func celebrateStep() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justCompleted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + config.checkMarkSeconds) { self.justCompleted = false }
    }
}
