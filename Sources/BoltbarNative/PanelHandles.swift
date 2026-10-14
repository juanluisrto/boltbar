import AppKit
import SwiftUI

/// AppKit tracks screen coordinates, so moving/resizing the window does not
/// change the drag's origin halfway through a gesture.
final class MoveAreaView: NSView {
    private var start: NSPoint?
    private var origin: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = window.convertPoint(toScreen: event.locationInWindow)
        origin = window.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start, let origin else { return }
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: origin.x + cursor.x - start.x, y: origin.y + cursor.y - start.y))
    }
    override func mouseUp(with event: NSEvent) { start = nil; origin = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
struct PanelMoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> MoveAreaView {
        let view = MoveAreaView()
        view.toolTip = "Drag to move the bar"
        view.setAccessibilityElement(true); view.setAccessibilityLabel("Move bar")
        return view
    }
    func updateNSView(_ view: MoveAreaView, context: Context) {}
}

final class ResizeAreaView: NSView {
    var begin: (() -> ((NSPoint) -> Void))?
    var resizeCursor = NSCursor.crosshair
    private var start: NSPoint?
    private var change: ((NSPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: resizeCursor) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = window.convertPoint(toScreen: event.locationInWindow)
        change = begin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start else { return }
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        change?(NSPoint(x: cursor.x - start.x, y: cursor.y - start.y))
    }
    override func mouseUp(with event: NSEvent) { start = nil; change = nil }
}
enum ResizeRegion: String, CaseIterable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    var left: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var right: Bool { self == .right || self == .topRight || self == .bottomRight }
    var top: Bool { self == .top || self == .topLeft || self == .topRight }
    var bottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .top: position = .top
            case .bottom: position = .bottom
            case .left: position = .left
            case .right: position = .right
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if (left || right) && (top || bottom) { return .crosshair }
        return left || right ? .resizeLeftRight : .resizeUpDown
    }
    func frame(from start: NSRect, delta: NSPoint, minimum: NSSize, maximum: NSSize) -> NSRect {
        var size = start.size
        if left || right { size.width = min(maximum.width, max(minimum.width, start.width + (right ? delta.x : -delta.x))) }
        if top || bottom { size.height = min(maximum.height, max(minimum.height, start.height + (top ? delta.y : -delta.y))) }
        return NSRect(x: left ? start.maxX - size.width : start.minX,
            y: bottom ? start.maxY - size.height : start.minY, width: size.width, height: size.height)
    }
}

struct PanelResizeArea: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    let region: ResizeRegion
    func makeNSView(context: Context) -> ResizeAreaView {
        let view = ResizeAreaView()
        view.resizeCursor = region.cursor
        view.setAccessibilityElement(true); view.setAccessibilityLabel("Resize \(region.rawValue) border")
        view.begin = { [weak view] in
            let start = view?.window?.frame ?? NSRect(x: 0, y: 0, width: 700, height: 112)
            let input = model.inputHeight
            let thread = model.manualThreadHeight ?? min(330, max(44, model.threadHeight))
            let hasMessages = !model.messages.isEmpty
            let history = model.showingHistory
            let available = view?.window?.screen?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
            let chrome = start.height - (history ? model.historyHeight : hasMessages ? thread : input)
            return { delta in
                let frame = region.frame(from: start, delta: delta,
                    minimum: NSSize(width: 420, height: chrome + (history ? 88 : hasMessages ? 44 : 26)),
                    maximum: NSSize(width: available.width - 20, height: available.height - 20))
                if frame.size != view?.window?.frame.size { model.resizeOrigin = frame.origin }
                model.panelWidth = frame.width
                if history { model.manualHistoryHeight = frame.height - chrome }
                else if hasMessages { model.manualThreadHeight = frame.height - chrome }
                else {
                    model.manualInputHeight = frame.height - chrome
                    model.inputHeight = model.manualInputHeight
                }
            }
        }
        return view
    }
    func updateNSView(_ view: ResizeAreaView, context: Context) {}
}

struct PanelBorders: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                PanelResizeArea(model: model, region: .top).frame(height: 6)
                Spacer(minLength: 0)
                PanelResizeArea(model: model, region: .bottom).frame(height: 6)
            }.padding(.horizontal, 14)
            HStack(spacing: 0) {
                PanelResizeArea(model: model, region: .left).frame(width: 6)
                Spacer(minLength: 0)
                PanelResizeArea(model: model, region: .right).frame(width: 6)
            }.padding(.vertical, 14)
            VStack(spacing: 0) {
                HStack { corner(.topLeft); Spacer(minLength: 0); corner(.topRight) }
                Spacer(minLength: 0)
                HStack { corner(.bottomLeft); Spacer(minLength: 0); corner(.bottomRight) }
            }
        }
    }
    func corner(_ region: ResizeRegion) -> some View {
        PanelResizeArea(model: model, region: region).frame(width: 14, height: 14)
    }
}
