import AppKit
import SwiftUI
import Carbon

final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ChatModel()
    var panel: ChatPanel!
    var settings: NSWindow?
    var status: NSStatusItem!
    var hotkey: EventHotKeyRef?
    var hotkeyHandler: EventHandlerRef?
    private var catalogTimer: Timer?
    private var attachmentPicker: NSOpenPanel?
    private var lastPanelSize = NSSize(width: 700, height: 107)
    private var bottomAnchor: CGFloat?
    private var adjustingAnchor = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.enableLocalHistory()
        makeMenu()
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 107), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Boltbar"; panel.delegate = self
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        let host = DropHostingView(rootView: ChatBar(model: model))
        host.registerForDraggedTypes([.fileURL, .png, .tiff]); host.accept = { [weak model] in model?.receive($0) ?? false }
        panel.contentView = host
        model.resize = { [weak self] in self?.fit($0) }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.presentFilePicker = { [weak self] in self?.showAttachmentPicker() }
        model.newConversation = { [weak self] in self?.show() }
        model.focusComposer = { [weak self] in self?.focusComposer() }
        model.updateShortcut = { [weak self] key, modifiers, label in
            guard let self, self.register(key, modifiers) else { return false }
            self.model.preferences.shortcutKey = key; self.model.preferences.shortcutModifiers = modifiers; self.model.preferences.shortcutLabel = label
            return true
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.show() }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
        let shortcutReady = register(model.preferences.shortcutKey, model.preferences.shortcutModifiers)
        show()
        if !shortcutReady {
            model.error = "The global shortcut is in use. Quit the other Boltbar version or choose another shortcut in Settings."
        }
        Task { await model.refresh() }
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
    }
    private func makeMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let newChat = appMenu.addItem(withTitle: "New chat", action: #selector(show), keyEquivalent: "n"); newChat.target = self
        let preferences = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); preferences.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Boltbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; root.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editItem.submenu = edit; root.addItem(editItem); NSApp.mainMenu = root
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Boltbar")
        status.button?.toolTip = "Boltbar"
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "New chat", action: #selector(self.show), keyEquivalent: ""); show.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Boltbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }
    func register(_ key: UInt32, _ modifiers: UInt32) -> Bool {
        if hotkey != nil, key == model.preferences.shortcutKey, modifiers == model.preferences.shortcutModifiers { return true }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x42424E41, id: 1), GetApplicationEventTarget(), 0, &next)
        metric(["kind": "hotkey", "status": result])
        guard result == noErr else { return false }
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = next
        return true
    }
    func fit(_ size: NSSize) {
        guard let panel, size.height > 0 else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let next = NSSize(width: min(visible.width - 20, max(420, ceil(size.width))), height: min(visible.height - 20, max(80, ceil(size.height))))
        guard abs(next.height - panel.frame.height) > 0.5 || abs(next.width - panel.frame.width) > 0.5 else { return }
        var frame = panel.frame; frame.size = next
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        // AppKit uses a bottom-left origin: preserving y grows the editor upward.
        panel.setFrame(frame, display: true)
    }
    @objc func show() {
        // A global shortcut must not reset the draft behind an open file sheet.
        if let attachmentPicker { attachmentPicker.makeKeyAndOrderFront(nil); return }
        let start = ProcessInfo.processInfo.systemUptime
        settings?.orderOut(nil)
        model.reset(); fit(NSSize(width: model.panelWidth, height: 112))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2)) }
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        focusComposer(); panel.displayIfNeeded()
        metric(["kind": "show_layout", "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
    }
    private func focusComposer() {
        guard attachmentPicker == nil else { return }
        func focus(_ view: NSView) {
            if let text = view as? ComposerTextView { panel.makeFirstResponder(text) } else { view.subviews.forEach(focus) }
        }
        if let view = panel.contentView { focus(view) }
    }
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        // A genuine move changes the origin without changing the size.
        if !adjustingAnchor, panel.frame.size == lastPanelSize { bottomAnchor = panel.frame.minY }
        recordFrame()
    }
    func windowDidResize(_ notification: Notification) {
        guard let panel, !adjustingAnchor else { return }
        // NSHostingView updates the intrinsic window size from the top edge.
        // Restore the bottom edge after that update so typing grows upward.
        if let requested = model.resizeOrigin {
            adjustingAnchor = true
            panel.setFrameOrigin(requested); model.resizeOrigin = nil
            adjustingAnchor = false
        } else if let bottomAnchor {
            adjustingAnchor = true
            let visible = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let y = max(visible.minY, min(bottomAnchor, visible.maxY - panel.frame.height))
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: y))
            adjustingAnchor = false
        }
        lastPanelSize = panel.frame.size; bottomAnchor = panel.frame.minY
        recordFrame()
    }
    private func recordFrame() {
        guard let panel else { return }
        metric(["kind": "panel_frame", "x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width, "height": panel.frame.height])
    }
    @objc func showSettings() {
        if let attachmentPicker { attachmentPicker.makeKeyAndOrderFront(nil); return }
        panel.orderOut(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Boltbar Settings"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 540); window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SettingsView(model: model)); window.center(); settings = window
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showAttachmentPicker() {
        if let attachmentPicker { attachmentPicker.makeKeyAndOrderFront(nil); return }
        let picker = NSOpenPanel()
        picker.title = "Attach images or documents"
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        attachmentPicker = picker
        NSApp.activate(ignoringOtherApps: true)
        // A sheet belongs to the floating panel, so AppKit orders it above its
        // parent instead of leaving an independent normal-level dialog behind.
        picker.beginSheetModal(for: panel) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.attachmentPicker = nil
                if result == .OK { self.model.addURLs(picker.urls) }
                self.panel.makeKeyAndOrderFront(nil)
                self.focusComposer()
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) { model.finish(); catalogTimer?.invalidate(); if let hotkey { UnregisterEventHotKey(hotkey) } }
}

@main struct BoltbarApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--qa-probe") {
            Task { await QAProbe.run() }
            dispatchMain()
        }
        let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
    }
}
