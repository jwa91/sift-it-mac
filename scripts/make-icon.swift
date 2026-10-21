// Draws the app's icon into Resources/AppIcon.icns: the Raycast extension's tile, a deep teal-to-indigo square with
// a magnifier full of sparkles, at every size macOS asks for.
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    // Apple's grid: an 824 pt tile in a 1024 pt canvas, with a corner of about 185.
    let tile = NSBezierPath(
        roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824).applying(scale),
        xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.09, green: 0.55, blue: 0.56, alpha: 1),
        NSColor(calibratedRed: 0.24, green: 0.23, blue: 0.67, alpha: 1),
    ])!
    .draw(in: tile, angle: -60)
    let configuration = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    let s = symbol.size
    symbol.draw(
        in: NSRect(
            x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2, width: s.width, height: s.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSRect {
    func applying(_ scale: CGFloat) -> NSRect {
        NSRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}

for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Resources/AppIcon.icns")
