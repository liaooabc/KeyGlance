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
