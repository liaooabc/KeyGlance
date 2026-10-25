import AppKit

/// Reads the system-wide keyboard shortcuts from `com.apple.symbolichotkeys`.
/// Values the user changed win; shortcuts the user switched off are hidden.
enum SystemShortcuts {

    private struct Definition {
        let id: Int
        let title: String
        /// Used when the system still has the factory binding (no entry in the plist).
        let defaultFlags: Int?
        let defaultASCII: Int
        let defaultKeyCode: Int
    }

    // id → name. Bindings come from the plist, defaults are macOS defaults.
    private static let definitions: [Definition] = [
        Definition(id: 32, title: "调度中心", defaultFlags: 0x40000, defaultASCII: 0xFFFF, defaultKeyCode: 126),
        Definition(id: 33, title: "应用窗口", defaultFlags: 0x40000, defaultASCII: 0xFFFF, defaultKeyCode: 125),
        Definition(id: 36, title: "显示桌面", defaultFlags: 0x800000, defaultASCII: 0xFFFF, defaultKeyCode: 103),
        Definition(id: 64, title: "聚焦搜索", defaultFlags: 0x100000, defaultASCII: 0x20, defaultKeyCode: 49),
        Definition(id: 65, title: "访达搜索", defaultFlags: 0x180000, defaultASCII: 0x20, defaultKeyCode: 49),
        Definition(id: 60, title: "上一个输入法", defaultFlags: 0x40000, defaultASCII: 0x20, defaultKeyCode: 49),
        Definition(id: 61, title: "下一输入法", defaultFlags: 0xC0000, defaultASCII: 0x20, defaultKeyCode: 49),
        Definition(id: 98, title: "强制退出", defaultFlags: 0x180000, defaultASCII: 0xFFFF, defaultKeyCode: 53),
        Definition(id: 118, title: "切换应用", defaultFlags: 0x100000, defaultASCII: 0xFFFF, defaultKeyCode: 48),
        Definition(id: 27, title: "循环切换窗口", defaultFlags: 0x100000, defaultASCII: 96, defaultKeyCode: 50),
        Definition(id: 28, title: "存储全屏", defaultFlags: 0x120000, defaultASCII: 0x33, defaultKeyCode: 20),
        Definition(id: 29, title: "拷贝全屏", defaultFlags: 0x160000, defaultASCII: 0x33, defaultKeyCode: 20),
        Definition(id: 30, title: "存储选区", defaultFlags: 0x120000, defaultASCII: 0x34, defaultKeyCode: 21),
        Definition(id: 31, title: "拷贝选区", defaultFlags: 0x160000, defaultASCII: 0x34, defaultKeyCode: 21),
        Definition(id: 184, title: "截屏与录制", defaultFlags: 0x120000, defaultASCII: 0x35, defaultKeyCode: 23)
    ]

    private struct StoredEntry {
        var enabled: Bool
        var parameters: [Int]?
    }

    static func section() -> ShortcutSection? {
        let stored = loadStoredEntries()
        var items: [ShortcutItem] = []

        for definition in definitions {
            let entry = stored[definition.id]
            if let entry, entry.enabled == false { continue }

            var caps: [String]?
            if let parameters = entry?.parameters, parameters.count >= 3, parameters[2] >= 0,
               parameters[1] != 0xFFFF || parameters[0] != 0xFFFF {
                caps = KeyCapFormatter.symbolicCaps(flags: parameters[2],
                                                    ascii: parameters[0],
                                                    keyCode: parameters[1])
            } else if let flags = definition.defaultFlags {
                caps = KeyCapFormatter.symbolicCaps(flags: flags,
                                                    ascii: definition.defaultASCII,
                                                    keyCode: definition.defaultKeyCode)
            }

            guard let caps, !caps.isEmpty else { continue }
            items.append(ShortcutItem(group: "系统", submenu: nil, title: definition.title, keys: caps))
        }

        guard items.count >= 3 else { return nil }
        return ShortcutSection(title: "系统", items: items)
    }

    private static func loadStoredEntries() -> [Int: StoredEntry] {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.symbolichotkeys.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let keys = plist["AppleSymbolicHotKeys"] as? [String: Any] else {
            return [:]
        }

        var result: [Int: StoredEntry] = [:]
        for (rawKey, rawValue) in keys {
            guard let id = Int(rawKey), let entry = rawValue as? [String: Any] else { continue }
            let enabled = entry["enabled"] as? Bool ?? false
            let value = entry["value"] as? [String: Any]
            let parameters = value?["parameters"] as? [Int]
            result[id] = StoredEntry(enabled: enabled, parameters: parameters)
        }
        return result
    }
}
