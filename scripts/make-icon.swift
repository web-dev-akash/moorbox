// Renders Moorbox's app icon to an .icns file. Run by scripts/package-app.sh:
//   swift scripts/make-icon.swift <output.icns>
// Drawn in code (no image assets in the repository): a rounded gradient tile with a
// device glyph resting on a "dock" bar.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Moorbox-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 tile, centred, corner radius ~185/1024.
    let tile = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.62, blue: 0.48, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.33, blue: 0.40, alpha: 1)])!.draw(in: path, angle: -90)

    // Dock bar.
    let bar = NSRect(x: s * 0.24, y: s * 0.22, width: s * 0.52, height: s * 0.055)
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()

    // Device glyph.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = glyph.size
        glyph.draw(in: NSRect(x: (s - size.width) / 2, y: s * 0.30, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
