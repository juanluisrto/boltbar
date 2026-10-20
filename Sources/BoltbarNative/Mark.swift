import AppKit

/// Two pieces of a chain link; the lightning bolt is the gap between them.
/// Geometry mirrors design/logo/boltbar-mark.svg (viewBox 229.5 163.5 1285 575) and scripts/make-icon.swift.
enum Mark {
    static let aspect: CGFloat = 1285 / 575

    /// Monochrome template for the menu bar, drawn at the screen's scale.
    static func statusImage(height: CGFloat = 8) -> NSImage {
        let image = NSImage(size: NSSize(width: (height * aspect).rounded(), height: height), flipped: false) { rect in
            path(in: rect).fill(); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Boltbar"
        return image
    }

    /// The mark scaled to fit `rect`, centred, in AppKit's bottom-left coordinates.
    static func path(in rect: NSRect) -> NSBezierPath {
        let s = min(rect.width / 1285, rect.height / 575)
        let ox = rect.midX - 1285 * s / 2, oy = rect.midY - 575 * s / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + (x - 229.5) * s, y: oy + (738.5 - y) * s) }
        func arc(_ path: NSBezierPath, _ cx: CGFloat, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat, clockwise: Bool) {
            path.appendArc(withCenter: point(cx, 451), radius: r * s, startAngle: from, endAngle: to, clockwise: clockwise)
        }
        let mark = NSBezierPath()
        mark.move(to: point(882.19, 163.5)); mark.line(to: point(517, 163.5))
        arc(mark, 517, 287.5, 90, 270, clockwise: false)
        mark.line(to: point(765.94, 738.5)); mark.line(to: point(900.97, 493)); mark.line(to: point(700.97, 493))
        mark.line(to: point(644.59, 595.5)); mark.line(to: point(517, 595.5))
        arc(mark, 517, 144.5, 270, 90, clockwise: true)
        mark.line(to: point(803.54, 306.5)); mark.close()
        mark.move(to: point(861.81, 738.5)); mark.line(to: point(1227, 738.5))
        arc(mark, 1227, 287.5, -90, 90, clockwise: false)
        mark.line(to: point(978.06, 163.5)); mark.line(to: point(843.03, 409)); mark.line(to: point(1043.03, 409))
        mark.line(to: point(1099.41, 306.5)); mark.line(to: point(1227, 306.5))
        arc(mark, 1227, 144.5, 90, -90, clockwise: true)
        mark.line(to: point(940.46, 595.5)); mark.close()
        return mark
    }
}
