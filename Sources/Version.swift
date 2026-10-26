import Foundation

/// 版本号比较。点分段按整数比（1.13 > 1.4），忽略 v 前缀和 -beta 之类的后缀。
enum Version {
    /// "v1.2.3-beta.1" → [1, 2, 3]
    static func parts(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        text = text.split(separator: "-").first.map(String.init) ?? text
        text = text.split(separator: "+").first.map(String.init) ?? text
        return text.split(separator: ".").map { component in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parts(lhs)
        let b = parts(rhs)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// 去掉 tag 里的 v / V，留下能显示的版本号。
    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }
}
