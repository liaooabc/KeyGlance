import AppKit

/// Counts which key combinations you actually press, per app, so the panel can
/// show a "常用" column. Only modifier combinations are stored — never text.
final class UsageTracker {
    static let shared = UsageTracker()

    private let defaults = UserDefaults.standard
    private let storageKey = "usageCounts"
    private var counts: [String: Int]
    private var flushWork: DispatchWorkItem?

    private init() {
        counts = [:]
        if let raw = defaults.dictionary(forKey: "usageCounts") {
            for (key, value) in raw {
                if let number = value as? Int {
                    counts[key] = number
                } else if let number = value as? NSNumber {
                    counts[key] = number.intValue
                } else if let text = value as? String, let number = Int(text) {
                    counts[key] = number
                }
            }
        }
    }

    func record(caps: [String], bundleID: String) {
        guard !bundleID.isEmpty, !caps.isEmpty else { return }
        let key = Self.storageKey(bundleID: bundleID, combo: caps.joined())
        counts[key, default: 0] += 1
        scheduleFlush()
    }

    func topCombos(bundleID: String, limit: Int) -> [String] {
        let prefix = bundleID + "|"
        return counts
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { String($0.key.dropFirst(prefix.count)) }
    }

    var totalCount: Int {
        counts.values.reduce(0, +)
    }

    func clear() {
        counts = [:]
        flushWork?.cancel()
        defaults.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: .usageTrackerCleared, object: nil)
    }

    private static func storageKey(bundleID: String, combo: String) -> String {
        "\(bundleID)|\(combo)"
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func flush() {
        if counts.count > 800 {
            let kept = counts.sorted { $0.value > $1.value }.prefix(500)
            counts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        defaults.set(counts, forKey: storageKey)
    }
}

extension Notification.Name {
    static let usageTrackerCleared = Notification.Name("KeyGlance.usageTrackerCleared")
}
