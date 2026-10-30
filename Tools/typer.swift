import CoreGraphics
import Foundation

// usage: typer <text>  — 用真实键盘事件输入 ASCII 文本（CGKeyCode）
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: typer text"); exit(1) }
let text = args[1]
let map: [Character: CGKeyCode] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "k": 40, "s": 1, "t": 17]
let source = CGEventSource(stateID: .hidSystemState)
for ch in text {
    guard let code = map[ch] else { continue }
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(60_000)
}
print("typed \(text)")
