// Renders Moorbox's app icon into an asset-catalog icon set:
//   swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
// The artwork is drawn in code so it can be regenerated and tweaked in review: a rounded
// gradient tile with a device glyph resting on a mooring bar.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset"
let iconset = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 tile, centred, corner radius ~185/1024.
    let tile = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.62, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.33, blue: 0.40, alpha: 1),
    ])!.draw(in: path, angle: -90)

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

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
