import AppKit
import ApplicationServices

struct ShortcutItem: Identifiable, Hashable {
    let id = UUID()
    let group: String
    let submenu: String?
    let title: String
    let keys: [String]

    var keyString: String { keys.joined() }

    var searchable: String {
        [group, submenu ?? "", title, keyString].joined(separator: " ")
    }
}

/// 搜索词匹配。除了字面包含，还支持：
/// - 英文称呼换成键帽符号（cmd / command / ctrl / option / alt / shift …）；
/// - 忽略空格和加号（"cmd+s"、"⌘ ⇧ S" 都能搜）；
/// - 修饰键顺序无关（"⌘⇧S" 也能命中 ⇧⌘S）。
enum ShortcutQuery {
    /// 长的写法在前：先替 "option"，否则 "opt" 会把 "option" 切成 "⌥ion"。
    private static let aliases: [(word: String, symbol: String)] = [
        ("command", "⌘"), ("control", "⌃"), ("option", "⌥"), ("shift", "⇧"),
        ("escape", "⎋"), ("return", "↩"), ("space", "空格"),
        ("backspace", "⌫"), ("delete", "⌫"), ("tab", "⇥"),
        ("cmd", "⌘"), ("ctrl", "⌃"), ("ctl", "⌃"), ("opt", "⌥"),
        ("alt", "⌥"), ("esc", "⎋"), ("enter", "↩")
    ]

    private static let modifierOrder: [Character] = ["⌃", "⌥", "⇧", "⌘"]

    /// 小写 + 英文称呼换成符号。
    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()
        for alias in aliases {
            text = text.replacingOccurrences(of: alias.word, with: alias.symbol)
        }
        return text
    }

    /// 去掉空格和加号：组合键怎么写都不该影响匹配。
    static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "+" }
    }

    /// 把修饰键按 ⌃⌥⇧⌘ 固定顺序排到前面，其余部分保持原序。
    static func canonicalModifiers(_ text: String) -> String {
        var seen = Set<Character>()
        var rest = ""
        for character in text {
            if modifierOrder.contains(character) {
                seen.insert(character)
            } else {
                rest.append(character)
            }
        }
        return String(modifierOrder.filter { seen.contains($0) }) + rest
    }

    static func matches(_ rawQuery: String, item: ShortcutItem) -> Bool {
        let haystack = compact(item.searchable.lowercased())
        guard !haystack.isEmpty else { return false }

        let literal = compact(rawQuery.lowercased())
        if !literal.isEmpty, haystack.contains(literal) { return true }

        let aliased = compact(normalize(rawQuery))
        if !aliased.isEmpty, haystack.contains(aliased) { return true }

        // 顺序无关：把两组修饰键都排成同一顺序，再只看快捷键那一截。
        let queryKeys = canonicalModifiers(aliased)
        let itemKeys = canonicalModifiers(compact(item.keyString.lowercased()))
        return !queryKeys.isEmpty && itemKeys.contains(queryKeys)
    }
}

struct ShortcutSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let items: [ShortcutItem]

    /// Cheap content fingerprint, used to skip needless re-renders.
    var signature: String {
        title + ":" + items.map { "\($0.title)|\($0.keyString)|\($0.submenu ?? "")" }.joined(separator: ";")
    }
}

/// Reads the menu bar of another process through the Accessibility API and turns
/// every menu item that has a key equivalent into a flat list of shortcuts.
enum ShortcutExtractor {

    static func sections(for application: NSRunningApplication) -> [ShortcutSection] {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return [] }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.5)

        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = axElement(from: menuBarValue) else {
            return []
        }

        var collected: [ShortcutItem] = []
        guard let topLevel = copyAttribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] else { return [] }

        for barItem in topLevel {
            let groupTitle = title(of: barItem)
            // The Apple menu is the system menu, not the app's own shortcuts.
            if groupTitle == "Apple" || groupTitle == "" { continue }
            guard let menus = copyAttribute(barItem, kAXChildrenAttribute) as? [AXUIElement],
                  let menu = menus.first else { continue }
            walk(menu: menu, group: groupTitle.isEmpty ? "其他" : groupTitle, submenu: nil, depth: 0, into: &collected)
        }

        // Group in menu order, keeping the original sequence inside each group.
        var order: [String] = []
        var buckets: [String: [ShortcutItem]] = [:]
        for item in collected {
            if buckets[item.group] == nil {
                buckets[item.group] = []
                order.append(item.group)
            }
            buckets[item.group]?.append(item)
        }
        return order.compactMap { name in
            guard let items = buckets[name], !items.isEmpty else { return nil }
            return ShortcutSection(title: name, items: items)
        }
    }

    // MARK: - Walking

    /// One IPC round trip per menu item instead of six.
    private static let itemAttributes: [String] = [
        kAXTitleAttribute as String,
        kAXChildrenAttribute as String,
        kAXMenuItemCmdCharAttribute as String,
        kAXMenuItemCmdModifiersAttribute as String,
        kAXMenuItemCmdVirtualKeyAttribute as String,
        kAXMenuItemCmdGlyphAttribute as String
    ]

    private static func attributes(of element: AXUIElement) -> [CFTypeRef] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, itemAttributes as CFArray, [], &values) == .success,
              let list = values as? [Any] else { return [] }
        return list.compactMap { raw in
            let value = raw as CFTypeRef
            // Unsupported attributes come back as an AXValue error placeholder.
            if CFGetTypeID(value) == AXValueGetTypeID() { return nil }
            return value
        }
    }

    private static func walk(menu: AXUIElement,
                             group: String,
                             submenu: String?,
                             depth: Int,
                             into result: inout [ShortcutItem]) {
        guard depth <= 3 else { return }
        guard let children = copyAttribute(menu, kAXChildrenAttribute) as? [AXUIElement] else { return }

        for child in children {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(child, itemAttributes as CFArray, [], &values) == .success,
                  let list = values as? [Any] else { continue }

            let itemTitle = (indexed(list, 0) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // A menu item that opens a submenu has no shortcut of its own (almost always).
            if let subs = indexed(list, 1) as? [AXUIElement], let subMenu = subs.first {
                if itemTitle == "服务" || itemTitle == "Services" || itemTitle.isEmpty { continue }
                walk(menu: subMenu, group: group, submenu: itemTitle, depth: depth + 1, into: &result)
                continue
            }

            guard !itemTitle.isEmpty else { continue }
            let modifiers = (indexed(list, 3) as? NSNumber)?.intValue ?? 8
            let character = indexed(list, 2) as? String
            let virtualKey = (indexed(list, 4) as? NSNumber)?.intValue
            let glyph = (indexed(list, 5) as? NSNumber)?.intValue ?? 0
            guard let keys = KeyCapFormatter.menuCaps(modifiers: modifiers,
                                                      character: character,
                                                      virtualKey: virtualKey,
                                                      glyph: glyph) else { continue }
            result.append(ShortcutItem(group: group, submenu: submenu, title: itemTitle, keys: keys))
        }
    }

    /// Returns the value at `index`, or nil when the slot held an AX error placeholder.
    private static func indexed(_ list: [Any], _ index: Int) -> Any? {
        guard index < list.count else { return nil }
        let raw = list[index]
        if CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() { return nil }
        return raw
    }

    // MARK: - Attribute helpers

    private static func axElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func title(of element: AXUIElement) -> String {
        (copyAttribute(element, kAXTitleAttribute) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func keyCaps(for element: AXUIElement) -> [String]? {
        let modifiers = (copyAttribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        let character = copyAttribute(element, kAXMenuItemCmdCharAttribute) as? String
        let virtualKey = (copyAttribute(element, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
        let glyph = (copyAttribute(element, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue ?? 0
        return KeyCapFormatter.menuCaps(modifiers: modifiers,
                                        character: character,
                                        virtualKey: virtualKey,
                                        glyph: glyph)
    }
}
