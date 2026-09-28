import Foundation
import Vision

/// Names you (or Claude) gave to objects, each with a small image fingerprint (Apple's
/// Vision "feature print"). When a similar-looking object shows up again, it's named from
/// here, on the phone, for free. Your own corrections win over AI answers.
///
/// Stored only on this phone: Application Support/object-memory.json.
/// Thread-safe: read on the analysis queue, written on the main thread.
final class ObjectMemory {
    static let shared = ObjectMemory()

    enum Source: String, Codable {
        case you      // your correction
        case ai       // Claude's answer (cached so we don't ask again)
    }

    struct Entry: Codable {
        var name: String
        var source: Source
        var details: String?
        var detectorLabel: String?
        var date: Date
        var fingerprint: Data   // archived VNFeaturePrintObservation
    }

    struct Match {
        var name: String
        var source: Source
        var details: String?
        var distance: Float
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var prints: [VNFeaturePrintObservation?] = []   // decoded, same order as entries
    private let fileURL: URL
    private let maxEntries = 500

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("object-memory.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
            prints = saved.map { Self.decode($0.fingerprint) }
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func counts() -> (yours: Int, ai: Int) {
        lock.lock(); defer { lock.unlock() }
        return (entries.filter { $0.source == .you }.count, entries.filter { $0.source == .ai }.count)
    }

    /// Remembers a name for an object that looks like `print`.
    func add(name: String, source: Source, details: String? = nil, detectorLabel: String?,
             print: VNFeaturePrintObservation) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return }
        lock.lock()
        entries.append(Entry(name: name, source: source, details: details, detectorLabel: detectorLabel,
                             date: Date(), fingerprint: data))
        prints.append(print)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
            prints.removeFirst(prints.count - maxEntries)
        }
        let snapshot = entries
        lock.unlock()
        save(snapshot)
        Log.info("Remembered \"\(name)\" (\(source.rawValue))")
    }

    /// The closest remembered object within `maxDistance`, preferring your own corrections.
    func bestMatch(for print: VNFeaturePrintObservation, maxDistance: Float) -> Match? {
        lock.lock()
        let current = Array(zip(entries, prints))
        lock.unlock()
        var bestYours: Match?
        var bestAI: Match?
        for (entry, stored) in current {
            guard let stored else { continue }
            var distance: Float = .greatestFiniteMagnitude
            guard (try? print.computeDistance(&distance, to: stored)) != nil, distance <= maxDistance else { continue }
            let match = Match(name: entry.name, source: entry.source, details: entry.details, distance: distance)
            switch entry.source {
            case .you: if bestYours == nil || distance < bestYours!.distance { bestYours = match }
            case .ai: if bestAI == nil || distance < bestAI!.distance { bestAI = match }
            }
        }
        return bestYours ?? bestAI
    }

    func reset() {
        lock.lock()
        entries = []
        prints = []
        lock.unlock()
        save([])
        Log.info("Object memory cleared")
    }

    private func save(_ snapshot: [Entry]) {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL) }
    }

    private static func decode(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}

/// Counts real Claude API calls (and answers served from the local cache instead).
/// Shown in Settings so you can see how rarely the cloud is used.
final class APIUsage: ObservableObject {
    static let shared = APIUsage()

    @Published private(set) var total: Int
    @Published private(set) var cacheHits: Int
    @Published private(set) var recentCalls: [Date]

    private let defaults = UserDefaults.standard

    private init() {
        total = defaults.integer(forKey: "apiCallsTotal")
        cacheHits = defaults.integer(forKey: "apiCacheHits")
        recentCalls = (defaults.array(forKey: "apiCallDates") as? [Date]) ?? []
    }

    var thisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return recentCalls.filter { $0 > weekAgo }.count
    }

    func recordCall() {
        total += 1
        recentCalls.append(Date())
        let monthAgo = Date().addingTimeInterval(-31 * 24 * 3600)
        recentCalls.removeAll { $0 < monthAgo }
        defaults.set(total, forKey: "apiCallsTotal")
        defaults.set(recentCalls, forKey: "apiCallDates")
    }

    func recordCacheHit() {
        cacheHits += 1
        defaults.set(cacheHits, forKey: "apiCacheHits")
    }
}
