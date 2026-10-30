import AppKit

// 生成 Icon Composer 的 .icon 包：白天（白底黑 ⌘）/ 暗夜（黑底白 ⌘）两套，
// 由系统在切换外观时自动替换。actool 负责编译成 Assets.car。

let outRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.icon")
let assets = outRoot.appendingPathComponent("Assets")
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func glyph(_ color: NSColor, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
    guard let base = NSImage(systemSymbolName: "command", accessibilityDescription: nil),
          let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight) as NSImage.SymbolConfiguration?,
          let symbol = base.withSymbolConfiguration(config) else { return nil }
    let size = symbol.size
    let output = NSImage(size: size)
    output.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: size))
    color.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    output.unlockFocus()
    return output
}

func makeIcon(background: NSColor, glyphColor: NSColor) -> Data? {
    let side: CGFloat = 1024
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(side), pixelsHigh: Int(side),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // 铺满画布：系统会自己套上超椭圆遮罩和投影
    background.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    if let mark = glyph(glyphColor, pointSize: 660, weight: .bold) {
        let target = NSRect(x: side / 2 - mark.size.width / 2,
                            y: side / 2 - mark.size.height / 2,
                            width: mark.size.width,
                            height: mark.size.height)
        mark.draw(in: target)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let dayBackground = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
let nightBackground = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)

guard let day = makeIcon(background: dayBackground, glyphColor: .black),
      let night = makeIcon(background: nightBackground, glyphColor: .white) else {
    print("failed to render")
    exit(1)
}
try day.write(to: assets.appendingPathComponent("day.png"))
try night.write(to: assets.appendingPathComponent("night.png"))

// 白天层只在浅色下出现；暗夜层在深色和着色模式下出现
let manifest: [String: Any] = [
    "fill": "system-light",
    "groups": [
        [
            "layers": [
                [
                    "image-name": "day.png",
                    "name": "Day",
                    "opacity-specializations": [
                        ["appearance": "dark", "value": 0.0],
                        ["appearance": "tinted", "value": 0.0]
                    ]
                ],
                [
                    "image-name": "night.png",
                    "name": "Night",
                    "opacity-specializations": [
                        ["appearance": "light", "value": 0.0]
                    ]
                ]
            ]
        ]
    ],
    "supported-platforms": ["squares": "shared"]
]

let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outRoot.appendingPathComponent("icon.json"))
print("icon package written to \(outRoot.path)")
