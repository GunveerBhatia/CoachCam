import CoreGraphics
import Foundation
import UIKit
import Vision
import VisionKit

/// What happens when you tap an object the phone can't name confidently. Free steps first;
/// the Claude API is the very last resort and only on your explicit tap.
///
///  1–2. (automatic, always running) live detector + Apple's classifier on a crop
///  3.   remembered names: your corrections and past AI answers, matched by image fingerprint
///  4.   Apple Visual Look Up on a still of the object (free, on the phone / Apple's service)
///  5.   "Identify with AI" (Claude) only if the above failed; the local cache is checked first,
///       and every answer is cached so a similar object never needs another call.
final class IdentifyController: ObservableObject {
    enum State: Equatable {
        case idle
        case offer                      // "Look Up (free)" button
        case lookingUp
        case lookUpReady                // Apple found something; sheet is showing
        case lookUpFailed               // Apple had nothing → offer AI / name it yourself
        case loading                    // asking Claude
        case result(name: String, detail: String, source: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var showLookUpSheet = false
    @Published private(set) var lookUpImage: UIImage?
    private(set) var lookUpAnalysis: ImageAnalysis?

    /// Tapped region (upright) and the object label it belongs to, if any.
    private(set) var region: CGRect?
    private var labelID: Int?
    private var localGuess: String?
    private var autoDismiss: DispatchWorkItem?

    let history = AINameHistory()

    // MARK: - Flow

    func offer(region: CGRect, labelID: Int?, localGuess: String?) {
        self.region = region
        self.labelID = labelID
        self.localGuess = localGuess
        state = .offer
        scheduleDismiss(after: 6)
    }

    func dismiss() {
        autoDismiss?.cancel()
        state = .idle
        region = nil
        labelID = nil
        showLookUpSheet = false
    }

    /// Step 4: Apple Visual Look Up on a still of the object.
    func lookUp(analyzer: SceneAnalyzer) {
        guard let region else { return }
        autoDismiss?.cancel()
        let crop = region.insetBy(dx: -region.width * 0.3, dy: -region.height * 0.3)
        guard let data = analyzer.snapshotJPEG(crop: crop, maxDimension: 1024), let image = UIImage(data: data) else {
            state = .failed("No camera frame yet. Try again.")
            return
        }
        guard ImageAnalyzer.isSupported else {
            state = .lookUpFailed
            return
        }
        state = .lookingUp
        lookUpImage = image
        Task { @MainActor in
            do {
                let configuration = ImageAnalyzer.Configuration([.visualLookUp])
                let analysis = try await ImageAnalyzer().analyze(image, configuration: configuration)
                if analysis.hasResults(for: .visualLookUp) {
                    self.lookUpAnalysis = analysis
                    self.state = .lookUpReady
                    self.showLookUpSheet = true
                    Log.info("Visual Look Up has a result")
                } else {
                    self.state = .lookUpFailed
                    Log.info("Visual Look Up: nothing found")
                }
            } catch {
                self.state = .lookUpFailed
                Log.warn("Visual Look Up failed: \(error.localizedDescription)")
            }
        }
    }

    /// You typed a name (after Look Up, or from a label). Remembered for next time.
    func nameIt(_ name: String, analyzer: SceneAnalyzer, tracker: ObjectLabelTracker) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let region else { return }
        if let print = analyzer.featurePrint(crop: region) {
            ObjectMemory.shared.add(name: clean, source: .you, detectorLabel: localGuess, print: print)
        }
        if let id = labelID { tracker.assign(id: id, name: clean, source: .you) }
        showLookUpSheet = false
        state = .result(name: clean, detail: "Saved. It'll be recognised next time.", source: "you")
        scheduleDismiss(after: 4)
    }

    /// Step 5: Claude, only when you tap. Checks the local cache first.
    func identifyWithAI(analyzer: SceneAnalyzer, tracker: ObjectLabelTracker) {
        guard let region else { return }
        autoDismiss?.cancel()
        showLookUpSheet = false
        let crop = region.insetBy(dx: -region.width * 0.15, dy: -region.height * 0.15)
        let print = analyzer.featurePrint(crop: region)

        // Cache first: a similar object already identified → no API call.
        if let print, let cached = ObjectMemory.shared.bestMatch(for: print,
                                                                 maxDistance: AppConfig.shared.naming.memoryMatchDistance) {
            APIUsage.shared.recordCacheHit()
            if let id = labelID { tracker.assign(id: id, name: cached.name, source: .remembered) }
            state = .result(name: cached.name, detail: cached.details ?? "From your saved names (no API call).",
                            source: cached.source == .you ? "you" : "cache")
            Log.info("Identify: answered from cache (\(cached.name), distance \(String(format: "%.2f", cached.distance)))")
            scheduleDismiss(after: 8)
            return
        }

        guard let jpeg = analyzer.snapshotJPEG(crop: crop, maxDimension: AppConfig.shared.ai.maxImageDimension) else {
            state = .failed("No camera frame yet. Try again.")
            return
        }
        state = .loading
        let guess = localGuess
        let id = labelID
        Log.info("Identify with AI: sending \(jpeg.count / 1024) KB crop")
        Task { @MainActor in
            do {
                let answer = try await ClaudeClient.identifyObject(jpeg: jpeg, localGuess: guess)
                APIUsage.shared.recordCall()
                if let print {
                    ObjectMemory.shared.add(name: answer.name, source: .ai, details: answer.details,
                                            detectorLabel: guess, print: print)
                }
                if let id { tracker.assign(id: id, name: answer.name, source: .ai) }
                self.history.add(answer.name)
                self.state = .result(name: answer.name,
                                     detail: "\(Int(answer.confidence * 100))% · \(answer.details)", source: "AI")
                Log.info("AI identified: \(answer.name) (\(Int(answer.confidence * 100))%)")
                self.scheduleDismiss(after: 10)
            } catch {
                // Count it if the request reached Anthropic (not for "no key" / "offline").
                switch error as? ClaudeClient.Failure {
                case .noAPIKey?, .offline?: break
                default: APIUsage.shared.recordCall()
                }
                self.state = .failed(error.localizedDescription)
                Log.warn("Identify with AI failed: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        autoDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.showLookUpSheet else { return }
            self.dismiss()
        }
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
