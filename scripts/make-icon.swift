// Reproducible native icon. Geometry mirrors Resources/AppIcon.svg.
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/Boltbar.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func draw(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    let panel = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    NSGradient(starting: color(0x17181b), ending: color(0x353638))!.draw(in: panel, angle: 90)
    NSColor.white.withAlphaComponent(0.12).setStroke(); panel.lineWidth = 2; panel.stroke()
    let bolt = NSBezierPath()
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 1024 - y) }
    // A crisp, recognisable lightning bolt, with gently rounded outer turns.
    bolt.move(to: point(562, 216)); bolt.line(to: point(304, 548))
    bolt.curve(to: point(312, 560), controlPoint1: point(296, 558), controlPoint2: point(300, 560))
    bolt.line(to: point(474, 560)); bolt.line(to: point(430, 798)); bolt.line(to: point(724, 450))
    bolt.curve(to: point(716, 438), controlPoint1: point(734, 438), controlPoint2: point(728, 438))
    bolt.line(to: point(550, 438)); bolt.line(to: point(600, 230))
    bolt.curve(to: point(586, 212), controlPoint1: point(604, 212), controlPoint2: point(602, 212))
    bolt.line(to: point(574, 212)); bolt.close()
    NSGradient(starting: color(0xf4ad39), ending: color(0xffdc89))!.draw(in: bolt, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try draw(size * scale).write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
