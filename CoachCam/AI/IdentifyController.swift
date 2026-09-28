import CoreGraphics
import Foundation

/// "Identify with AI": offered after you tap something the phone can't name confidently.
/// Nothing is sent unless you press the button. Only a small crop around the tapped
/// spot is sent (config.json → ai.maxImageDimension).
final class IdentifyController: ObservableObject {
    enum State: Equatable {
        case idle
        case offer
        case loading
        case result(name: String, confidence: Double, details: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The tapped region (upright coordinates).
    @Published private(set) var region: CGRect?
    let history = AINameHistory()

    private var localGuess: String?
    private var autoDismiss: DispatchWorkItem?

    /// Shows the "Identify with AI" button for a few seconds.
    func offer(region: CGRect, localGuess: String?) {
        self.region = region
        self.localGuess = localGuess
        state = .offer
        scheduleDismiss(after: 6)
    }

    func dismiss() {
        autoDismiss?.cancel()
        state = .idle
        region = nil
    }

    /// Sends the crop to Claude. Called only from the button.
    func identify(using analyzer: SceneAnalyzer) {
        guard let region else { return }
        autoDismiss?.cancel()
        // A little context around the object helps.
        let crop = region.insetBy(dx: -region.width * 0.15, dy: -region.height * 0.15)
        guard let jpeg = analyzer.snapshotJPEG(crop: crop, maxDimension: AppConfig.shared.ai.maxImageDimension) else {
            state = .failed("No camera frame yet. Try again.")
            return
        }
        state = .loading
        let guess = localGuess
        Log.info("Identify with AI: sending \(jpeg.count / 1024) KB crop")
        Task { @MainActor in
            do {
                let answer = try await ClaudeClient.identifyObject(jpeg: jpeg, localGuess: guess)
                self.state = .result(name: answer.name, confidence: answer.confidence, details: answer.details)
                self.history.add(answer.name)
                Log.info("AI identified: \(answer.name) (\(Int(answer.confidence * 100))%)")
                self.scheduleDismiss(after: 10)
            } catch {
                self.state = .failed(error.localizedDescription)
                Log.warn("Identify with AI failed: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        autoDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Names Claude has identified, newest first, stored on the phone. Share them from Settings
/// to add the useful ones to vocabulary.json so the on-device detector learns them.
final class AINameHistory: ObservableObject {
    @Published private(set) var names: [String]
    private let key = "aiIdentifiedNames"

    init() {
        names = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        names.removeAll { $0.caseInsensitiveCompare(clean) == .orderedSame }
        names.insert(clean, at: 0)
        if names.count > 100 { names.removeLast(names.count - 100) }
        UserDefaults.standard.set(names, forKey: key)
    }

    func clear() {
        names = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
