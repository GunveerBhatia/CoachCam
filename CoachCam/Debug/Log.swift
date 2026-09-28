import Foundation

/// Simple app-wide logger.
///
/// - Writes every line to `Documents/coachcam-log.txt`. You can see that file in the
///   Files app (On My iPhone → Coach Cam) and share it from Settings → Debug log.
/// - Keeps the most recent entries in memory for the in-app log viewer.
///
/// Usage: `Log.info("Camera started")`, `Log.warn("...")`, `Log.error("...")`.
/// (Named `Log` rather than `log` because `log()` is already the math function.)
enum Log {
    static func info(_ message: String) { LogStore.shared.add(.info, message) }
    static func warn(_ message: String) { LogStore.shared.add(.warn, message) }
    static func error(_ message: String) { LogStore.shared.add(.error, message) }
}

final class LogStore: ObservableObject {
    static let shared = LogStore()

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    /// Newest entries last. Only touched on the main thread.
    @Published private(set) var entries: [Entry] = []

    let fileURL: URL
    private let fileQueue = DispatchQueue(label: "coachcam.log")
    private let maxInMemory = 500
    private let maxFileBytes = 2_000_000   // Start a fresh file when it passes about 2 MB.

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("coachcam-log.txt")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func add(_ level: Level, _ message: String) {
        let entry = Entry(date: Date(), level: level, message: message)
        let line = "\(Self.lineFormatter.string(from: entry.date)) [\(level.rawValue)] \(message)\n"
        fileQueue.async { self.append(line) }
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxInMemory {
                self.entries.removeFirst(self.entries.count - self.maxInMemory)
            }
        }
    }

    /// Writes immediately on the calling thread. Only used by the crash handler,
    /// because the app is about to die and async work would never run.
    func writeNow(_ message: String) {
        append("\(Self.lineFormatter.string(from: Date())) [CRASH] \(message)\n")
    }

    func clear() {
        fileQueue.async {
            try? Data().write(to: self.fileURL)
        }
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    /// Everything in the log file (used when sharing).
    func fullText() -> String {
        fileQueue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size > maxFileBytes {
            try? Data().write(to: fileURL)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Catches Objective-C exceptions (AVFoundation throws these when it's misconfigured)
    /// and writes them to the log before the app closes.
    static func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n")
            LogStore.shared.writeNow("\(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)")
        }
    }
}
