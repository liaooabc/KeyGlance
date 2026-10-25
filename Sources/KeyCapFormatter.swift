import AppKit

/// Turns key equivalents (from menus, from system hot key settings, or from live
/// key events) into the same ordered list of key caps, e.g. ["⌃", "⌥", "⇧", "⌘", "P"].
enum KeyCapFormatter {

    static func caps(control: Bool, option: Bool, shift: Bool, command: Bool, key: String) -> [String] {
        guard !key.isEmpty else { return [] }
        var caps: [String] = []
        if control { caps.append("⌃") }
        if option { caps.append("⌥") }
        if shift { caps.append("⇧") }
        if command { caps.append("⌘") }
        caps.append(key)
        return caps
    }

    /// Menu item key equivalent: `modifiers` is the AX menu item mask
    /// (1 shift, 2 option, 4 control, 8 "no command").
    static func menuCaps(modifiers: Int, character: String?, virtualKey: Int?, glyph: Int) -> [String]? {
        if modifiers & 8 != 0 { return nil }
        var key = ""
        if let character, !character.isEmpty, let scalar = character.unicodeScalars.first,
           scalar.value >= 0x20, scalar.value != 0x7F {
            key = character.uppercased()
        }
        if key.isEmpty, let virtualKey, let mapped = virtualKeyName(virtualKey) {
            key = mapped
        }
        if key.isEmpty, glyph != 0 {
            key = glyphName(glyph) ?? ""
        }
        if key.isEmpty { return nil }
        return caps(control: modifiers & 4 != 0,
                    option: modifiers & 2 != 0,
                    shift: modifiers & 1 != 0,
                    command: true,
                    key: key)
    }

    /// System hot keys (`com.apple.symbolichotkeys`) use NSEvent modifier flags
    /// plus an ASCII character (`0xFFFF` when the key is not a character).
    static func symbolicCaps(flags: Int, ascii: Int, keyCode: Int) -> [String]? {
        guard keyCode != 0xFFFF || ascii != 0xFFFF else { return nil }
        var key = ""
        if let mapped = virtualKeyName(keyCode) {
            key = mapped
        }
        if key.isEmpty, ascii != 0xFFFF, ascii > 0x20, ascii < 0x7F {
            key = String(UnicodeScalar(UInt8(ascii))).uppercased()
        }
        if key.isEmpty { return nil }
        return caps(control: flags & 0x40000 != 0,
                    option: flags & 0x80000 != 0,
                    shift: flags & 0x20000 != 0,
                    command: flags & 0x100000 != 0,
                    key: key)
    }

    /// Live key event. Returns nil for plain typing (no ⌘ / ⌃ / ⌥), so nothing
    /// that a user types can ever be recorded.
    static func eventCaps(_ event: NSEvent) -> [String]? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }

        var key = characterForKeyCode(Int(event.keyCode)) ?? ""
        if key.isEmpty, let mapped = virtualKeyName(Int(event.keyCode)) {
            key = mapped
        }
        if key.isEmpty, let typing = event.characters(byApplyingModifiers: [])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !typing.isEmpty,
           let scalar = typing.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F {
            key = typing.uppercased()
        }
        if key.isEmpty { return nil }
        return caps(control: flags.contains(.control),
                    option: flags.contains(.option),
                    shift: flags.contains(.shift),
                    command: flags.contains(.command),
                    key: key)
    }

    // MARK: - Key names

    /// ANSI / US layout labels, so matching never depends on the active input method.
    static func characterForKeyCode(_ code: Int) -> String? {
        switch code {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 50: return "`"
        default: return nil
        }
    }

    static func virtualKeyName(_ code: Int) -> String? {
        switch code {
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "空格"
        case 51: return "⌫"
        case 117: return "⌦"
        case 53: return "⎋"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return nil
        }
    }

    private static func glyphName(_ glyph: Int) -> String? {
        switch glyph {
        case 23: return "⌫"
        case 2: return "↩"
        case 3: return "⇥"
        case 4: return "⎋"
        default: return nil
        }
    }
}
