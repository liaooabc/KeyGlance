import CoreGraphics
import Foundation
// usage: keyer <keyCode> [repeat]
let args = CommandLine.arguments
guard args.count >= 2, let code = UInt16(args[1]) else { print("usage: keyer code [n]"); exit(1) }
let times = args.count > 2 ? (Int(args[2]) ?? 1) : 1
let source = CGEventSource(stateID: .hidSystemState)
for _ in 0..<times {
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(120_000)
}
print("sent \(code) x\(times)")
