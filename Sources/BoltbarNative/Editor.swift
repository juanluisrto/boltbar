import AppKit
import SwiftUI

/// A multiline composer never scrolls sideways to follow its insertion point.
final class EditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}

final class EditorScrollView: NSScrollView {
    var measured: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, contentSize.width > 0,
              abs(text.frame.width - contentSize.width) > 0.5 else { return }
        text.setFrameSize(NSSize(width: contentSize.width, height: max(26, text.frame.height)))
        DispatchQueue.main.async { [weak self, weak text] in
            guard let text, let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            self?.measured?(ceil(layout.usedRect(for: container).height + 6))
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHistory: (() -> Void)?
    var onBackToHistory: (() -> Bool)?
    var onAttachment: ((NSPasteboard) -> Bool)?
    override func paste(_ sender: Any?) {
        if onAttachment?(.general) == true { return }
        super.paste(sender)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.orderOut(nil); return }
        if string.isEmpty, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if event.keyCode == 124 { onHistory?(); return }
            if event.keyCode == 123, onBackToHistory?() == true { return }
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "n": onNewChat?(); return
            case ",": onSettings?(); return
            case "q": NSApp.terminate(nil); return
            case "v": paste(nil); return
            case "a": selectAll(nil); return
            case "c": copy(nil); return
            case "x": cut(nil); return
            default: break
            }
        }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { onSend?(); return }
        super.keyDown(with: event)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) == nil ? super.draggingEntered(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onAttachment?(sender.draggingPasteboard) == true || super.performDragOperation(sender)
    }
}

struct GrowingEditor: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    static func height(for content: CGFloat, manual: CGFloat = 26) -> CGFloat { max(manual, min(160, max(26, content))) }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 668, height: 26))
        scroll.contentView = EditorClipView(frame: scroll.bounds)
        scroll.contentView.drawsBackground = false
        scroll.measured = { model.inputHeight = Self.height(for: $0, manual: model.manualInputHeight) }
        let text = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 668, height: 26))
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.documentView = text
        scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true
        text.isRichText = false; text.drawsBackground = false; text.textColor = .white
        text.insertionPointColor = .white; text.font = .systemFont(ofSize: 15)
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        // Keep an empty document clickable after sending clears its text.
        text.minSize = NSSize(width: 0, height: 26)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 668, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator
        text.onSend = { model.send() }; text.onAttachment = { model.receive($0) }
        text.onNewChat = { model.newConversation?() }; text.onSettings = { model.openSettings?() }
        text.onHistory = { model.showHistory(preservingSearch: model.canReturnToHistory) }
        text.onBackToHistory = { model.returnToHistory() }
        text.registerForDraggedTypes([.fileURL, .png, .tiff])
        text.setAccessibilityLabel("Message")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? ComposerTextView else { return }
        if text.string != model.draft { text.string = model.draft }
        scroll.hasVerticalScroller = model.inputHeight >= 160
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ChatModel
        init(_ model: ChatModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView,
                  let layout = text.layoutManager, let container = text.textContainer else { return }
            model.draft = text.string; layout.ensureLayout(for: container)
            model.inputHeight = GrowingEditor.height(for: ceil(layout.usedRect(for: container).height + 6), manual: model.manualInputHeight)
        }
    }
}

final class DropHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    var accept: ((NSPasteboard) -> Bool)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { accept?(sender.draggingPasteboard) ?? false }
}
