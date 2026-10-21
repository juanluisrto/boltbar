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
    var onPickerKey: ((UInt16) -> Bool)?
    var onCycleModel: ((Int) -> Void)?
    var onStepEffort: ((Int) -> Bool)?
    var onEndModelSelection: (() -> Bool)?
    var onCancelEdit: (() -> Bool)?
    /// Agent mode, help and approvals. Each returns whether it used the key.
    var onApprove: ((Bool) -> Bool)?
    var onDismissOverlay: (() -> Bool)?
    var onToggleAgent: (() -> Void)?
    var agentShortcut: () -> AgentShortcut = { AgentShortcut() }
    var onHelp: (() -> Void)?
    var onAgentKey: ((UInt16) -> Bool)?
    var onTab: ((Bool) -> Bool)?
    var onSelectChat: (() -> Bool)?
    var onCompleteCommand: (() -> Bool)?
    override func mouseDown(with event: NSEvent) {
        _ = onEndModelSelection?(); super.mouseDown(with: event)
    }
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
        if hasMarkedText() { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⌘↵ allows and ⌥⌘↵ allows in this chat: never a bare Return, which is too easy to press twice.
        if event.keyCode == 36, flags.contains(.command), !event.isARepeat, onApprove?(flags.contains(.option)) == true { return }
        if flags.contains(.command), !flags.contains(.control), matches(agentShortcut(), event) { onToggleAgent?(); return }
        if flags == [.command, .shift], ["/", "?"].contains(event.charactersIgnoringModifiers) { onHelp?(); return }
        if flags.isEmpty, onPickerKey?(event.keyCode) == true { return }
        if flags.isEmpty, onAgentKey?(event.keyCode) == true { return }
        if event.keyCode == 53 {
            if onDismissOverlay?() != true && onEndModelSelection?() != true && onCancelEdit?() != true { window?.orderOut(nil) }
            return
        }
        if event.keyCode == 48, flags.isEmpty || flags == .shift {
            if string.hasPrefix("/"), onCompleteCommand?() == true { return }
            if string.isEmpty, onTab?(flags != .shift) == true { return }
        }
        if string.isEmpty, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if event.keyCode == 125 || event.keyCode == 126 { onCycleModel?(event.keyCode == 125 ? 1 : -1); return }
            if event.keyCode == 123 || event.keyCode == 124,
               onStepEffort?(event.keyCode == 124 ? 1 : -1) == true { return }
            if event.keyCode == 36, onEndModelSelection?() == true { return }
            if event.keyCode == 124 { onHistory?(); return }
            if event.keyCode == 123, onBackToHistory?() == true { return }
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "n": onNewChat?(); return
            case ",": onSettings?(); return
            case "q": NSApp.terminate(nil); return
            case "v": paste(nil); return
            // ⌘A in an empty field selects the whole chat; with text, the field's own.
            case "a": if string.isEmpty, onSelectChat?() == true { return }; selectAll(nil); return
            case "c": copy(nil); return
            case "x": cut(nil); return
            default: break
            }
        }
        // A held Return must not queue a message and then, once the field is
        // empty, interrupt the reply with its repeats.
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            if !event.isARepeat { onSend?() }
            return
        }
        if event.characters?.contains(where: { !$0.isNewline && !$0.isWhitespace }) == true || event.keyCode == 49 { _ = onEndModelSelection?() }
        super.keyDown(with: event)
    }
    private func matches(_ shortcut: AgentShortcut, _ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        return flags.contains(.shift) == shortcut.shift && flags.contains(.option) == shortcut.option
            && event.charactersIgnoringModifiers?.lowercased() == shortcut.key.lowercased()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) == nil ? super.draggingEntered(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onAttachment?(sender.draggingPasteboard) == true || super.performDragOperation(sender)
    }
}

struct GrowingEditor: NSViewRepresentable {
    @Environment(\.boltbarTheme) private var theme
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
        text.isRichText = false; text.drawsBackground = false; text.textColor = theme.textNS
        text.insertionPointColor = theme.accentNS; text.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        // Keep an empty document clickable after sending clears its text.
        text.minSize = NSSize(width: 0, height: 26)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 668, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator
        text.onPickerKey = { code in
            guard model.showingModelPicker else { return false }
            switch code {
            case 125, 126: model.cycleModel(code == 125 ? 1 : -1)
            case 123, 124: model.stepEffort(code == 124 ? 1 : -1)
            case 36, 53: model.endModelSelection()
            case 48: return false // Tab walks on to the agent chip.
            default: model.endModelSelection(); return false
            }
            return true
        }
        text.onCycleModel = { model.cycleModel($0) }
        text.onStepEffort = { direction in
            guard model.selectingModel else { return false }
            model.stepEffort(direction); return true
        }
        text.onEndModelSelection = { model.endModelSelection() }
        text.onCancelEdit = { model.cancelQueuedEdit() }
        text.onApprove = { forChat in
            guard model.pendingApproval != nil else { return false }
            model.resolveApproval(forChat ? .allowForChat : .allow); return true
        }
        text.onDismissOverlay = {
            if model.pendingApproval != nil { model.resolveApproval(.deny); return true }
            if model.showingHelp { model.closeHelp(); return true }
            return false
        }
        text.onToggleAgent = { model.toggleAgentMode() }
        text.agentShortcut = { model.agentSettings.shortcut }
        text.onHelp = { model.showHelp() }
        text.onTab = { forward in model.switchChipSelection(forward: forward) }
        text.onSelectChat = { model.selectChat?() ?? false }
        text.onCompleteCommand = {
            let typed = model.draft.lowercased()
            guard let match = HelpContent.commands.first(where: { $0.command.hasPrefix(typed) }) else { return false }
            model.draft = match.command; return true
        }
        // On the agent chip: ↑ ↓ project, ← → permission, ⌫ twice removes, ↵ turns agent mode on or off.
        text.onAgentKey = { code in
            guard model.selectingAgent || model.showingAgentPicker else { return false }
            if code == 48 { return false } // Tab stays here; ⇧Tab goes back.
            if !model.agentMode {
                switch code {
                case 36: model.toggleAgentMode(keepingSelection: true)
                case 53: model.endModelSelection()
                case 123...126: break
                default: model.endModelSelection(); return false
                }
                return true
            }
            switch code {
            case 125, 126: model.cycleProject(code == 125 ? 1 : -1)
            case 123, 124: model.stepPermission(code == 124 ? 1 : -1)
            case 51, 117: model.requestProjectRemoval()
            // In the popover a click opened, ↵ just closes it.
            case 36 where model.selectingAgent && !model.showingAgentPicker: model.toggleAgentMode(keepingSelection: true)
            case 36, 53: model.endModelSelection()
            default: model.endModelSelection(); return false
            }
            return true
        }
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
        // This runs on every redraw, once per streamed word too. Recolouring the whole text each time made
        // typing during a reply stutter and flicker, so colours change only with the theme.
        let coordinator = context.coordinator
        if coordinator.textColor != theme.textNS || coordinator.accentColor != theme.accentNS {
            coordinator.textColor = theme.textNS; coordinator.accentColor = theme.accentNS
            text.textColor = theme.textNS; text.insertionPointColor = theme.accentNS
            text.selectedTextAttributes = [.backgroundColor: theme.accentNS.withAlphaComponent(0.25), .foregroundColor: theme.textNS]
        }
        if text.string != model.draft { text.string = model.draft }
        let scrolls = model.inputHeight >= 160
        if scroll.hasVerticalScroller != scrolls { scroll.hasVerticalScroller = scrolls }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ChatModel
        var textColor: NSColor?, accentColor: NSColor?
        init(_ model: ChatModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView,
                  let layout = text.layoutManager, let container = text.textContainer else { return }
            model.draft = text.string; layout.ensureLayout(for: container)
            let height = GrowingEditor.height(for: ceil(layout.usedRect(for: container).height + 6), manual: model.manualInputHeight)
            if model.inputHeight != height { model.inputHeight = height }
        }
    }
}

final class DropHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    var accept: ((NSPasteboard) -> Bool)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { accept?(sender.draggingPasteboard) ?? false }
}
