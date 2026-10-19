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
    // Two pieces of a chain link; the lightning bolt is the gap between them.
    // Coordinates are the logo's 1744×902 design space, placed as in AppIcon.svg.
    let s: CGFloat = 0.51362, tx: CGFloat = 64.12, ty: CGFloat = 280.36
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: tx + x * s, y: 1024 - (ty + y * s)) }
    func arc(_ path: NSBezierPath, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat, clockwise: Bool) {
        path.appendArc(withCenter: point(cx, cy), radius: r * s, startAngle: from, endAngle: to, clockwise: clockwise)
    }
    let mark = NSBezierPath()
    mark.move(to: point(882.19, 163.5)); mark.line(to: point(517, 163.5))
    arc(mark, 517, 451, 287.5, 90, 270, clockwise: false)
    mark.line(to: point(765.94, 738.5)); mark.line(to: point(900.97, 493)); mark.line(to: point(700.97, 493))
    mark.line(to: point(644.59, 595.5)); mark.line(to: point(517, 595.5))
    arc(mark, 517, 451, 144.5, 270, 90, clockwise: true)
    mark.line(to: point(803.54, 306.5)); mark.close()
    mark.move(to: point(861.81, 738.5)); mark.line(to: point(1227, 738.5))
    arc(mark, 1227, 451, 287.5, -90, 90, clockwise: false)
    mark.line(to: point(978.06, 163.5)); mark.line(to: point(843.03, 409)); mark.line(to: point(1043.03, 409))
    mark.line(to: point(1099.41, 306.5)); mark.line(to: point(1227, 306.5))
    arc(mark, 1227, 451, 144.5, 90, -90, clockwise: true)
    mark.line(to: point(940.46, 595.5)); mark.close()
    NSGradient(starting: color(0xf4ad39), ending: color(0xffdc89))!.draw(in: mark, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try draw(size * scale).write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
