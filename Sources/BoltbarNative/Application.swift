import AppKit
import SwiftUI
import Carbon

final class ChatPanel: NSPanel {
    var onHide: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    // Every way of hiding the bar (Esc, Settings) ends here.
    override func orderOut(_ sender: Any?) { super.orderOut(sender); onHide?() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = ChatModel()
    private lazy var updater = AppUpdater(model: model)
    var panel: ChatPanel!
    var settings: NSWindow?
    var status: NSStatusItem!
    var hotkey: EventHotKeyRef?
    var hotkeyHandler: EventHandlerRef?
    private var catalogTimer: Timer?
    private var layoutTimer: Timer?
    /// Where a layout change grows from, and the bar around what it resizes. Kept while it animates:
    /// the window trails the model by a frame, so a second click can't measure them mid-way.
    private var layoutAnchor: (top: NSPoint, chrome: CGFloat)?
    private var buyLicenseItem: NSMenuItem?
    private var attachmentPicker: NSOpenPanel?
    private var lastPanelSize = NSSize(width: 700, height: 107)
    private var bottomAnchor: CGFloat?
    private var adjustingAnchor = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.enableLocalHistory()
        _ = updater
        makeMenu()
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 107), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Boltbar"; panel.delegate = self
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.onHide = { [weak model] in model?.barHidden() }
        let host = DropHostingView(rootView: ThemedView(model: model) { ChatBar(model: model) })
        host.registerForDraggedTypes([.fileURL, .png, .tiff]); host.accept = { [weak model] in model?.receive($0) ?? false }
        panel.contentView = host
        model.resize = { [weak self] in self?.fit($0) }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.presentFilePicker = { [weak self] in self?.showAttachmentPicker() }
        model.presentFolderPicker = { [weak self] in self?.showFolderPicker() }
        model.newConversation = { [weak self] in self?.newChat() }
        model.focusComposer = { [weak self] in self?.focusComposer() }
        model.hideBar = { [weak self] in self?.panel.orderOut(nil) }
        model.applyLayout = { [weak self] in self?.apply($0) }
        model.updateShortcut = { [weak self] key, modifiers, label in
            guard let self, self.register(key, modifiers) else { return false }
            self.model.preferences.shortcutKey = key; self.model.preferences.shortcutModifiers = modifiers; self.model.preferences.shortcutLabel = label
            return true
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.summon() }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
        let shortcutReady = register(model.preferences.shortcutKey, model.preferences.shortcutModifiers)
        summon()
        if !shortcutReady {
            model.error = "The global shortcut is in use. Quit the other Boltbar version or choose another shortcut in Settings."
        }
        Task { await model.refresh() }
        Task { await model.loadLicense() }
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
    }
    private func makeMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let newChatItem = appMenu.addItem(withTitle: "New chat", action: #selector(self.newChat), keyEquivalent: "n"); newChatItem.target = self
        let preferences = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); preferences.target = self
        let update = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: ""); update.target = updater
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Boltbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; root.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editItem.submenu = edit; root.addItem(editItem); NSApp.mainMenu = root
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = Mark.statusImage()
        status.button?.toolTip = "Boltbar"
        let menu = NSMenu()
        let newChatStatus = menu.addItem(withTitle: "New chat", action: #selector(self.newChat), keyEquivalent: ""); newChatStatus.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        let updateStatus = menu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: ""); updateStatus.target = updater
        let buy = menu.addItem(withTitle: "Buy a license…", action: #selector(buyLicense), keyEquivalent: ""); buy.target = self; buyLicenseItem = buy
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Boltbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in [root, appMenu, edit, menu] { item.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        menu.delegate = self; status.menu = menu
    }
    /// Only an unlicensed copy offers a license; one the Keychain hasn't answered for yet doesn't.
    func menuNeedsUpdate(_ menu: NSMenu) { buyLicenseItem?.isHidden = model.licenseState != .unlicensed }
    @objc func buyLicense() { model.buyLicense() }
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
    /// Compact trims the bar to a small reading size; column makes it narrow
    /// and about two-thirds of the screen tall, for keeping beside other windows.
    /// The bar grows or shrinks there from its top left, so the button stays under the pointer.
    private func apply(_ layout: PanelLayout) {
        guard let panel else { return }
        layoutTimer?.invalidate()
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        // Only history or the thread changes height; an empty chat or help keeps its own.
        let history = model.showingHistory, thread = model.showingThread
        let fromHeight = history ? model.historyHeight : thread ? model.manualThreadHeight ?? min(330, max(44, model.threadHeight)) : 0
        let anchor = layoutAnchor ?? (top: NSPoint(x: panel.frame.minX, y: panel.frame.maxY), chrome: panel.frame.height - fromHeight)
        let top = anchor.top, chrome = anchor.chrome
        layoutAnchor = anchor
        let fromWidth = model.panelWidth, toWidth: CGFloat = layout == .compact ? 520 : 440
        var toHeight = fromHeight
        switch layout {
        case .compact:
            if history { toHeight = model.naturalHistoryHeight } else if thread { toHeight = min(200, max(44, model.threadHeight)) }
        case .column:
            if history || thread { toHeight = max(88, min(720, visible.height * 0.66) - chrome) }
        }
        let began = ProcessInfo.processInfo.systemUptime
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
        // Each step resizes like a drag on the border: set the origin, then the sizes the bar lays out to.
        func step() -> Bool {
            let t = duration > 0 ? min(1, (ProcessInfo.processInfo.systemUptime - began) / duration) : 1
            let eased = CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2)
            let width = fromWidth + (toWidth - fromWidth) * eased, height = fromHeight + (toHeight - fromHeight) * eased
            let size = NSSize(width: ceil(max(420, width)), height: ceil(chrome + height))
            let origin = NSPoint(x: min(top.x, visible.maxX - size.width), y: max(visible.minY, min(top.y, visible.maxY) - size.height))
            if abs(size.width - panel.frame.width) > 0.5 || abs(size.height - panel.frame.height) > 0.5 { model.resizeOrigin = origin }
            model.panelWidth = width
            if history { model.manualHistoryHeight = height } else if thread { model.manualThreadHeight = height }
            guard t >= 1 else { return false }
            // Compact hands history back its natural height, which follows the list.
            if layout == .compact { model.manualHistoryHeight = nil }
            layoutAnchor = nil
            return true
        }
        guard !step() else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { if step() { timer.invalidate(); self?.layoutTimer = nil } }
        }
        RunLoop.main.add(timer, forMode: .common); layoutTimer = timer
    }
    /// The global shortcut: a new chat, or the current one while it is still working.
    func summon() { present(newChat: false) }
    /// ⌘N and the New chat menu items always start over.
    @objc func newChat() { present(newChat: true) }
    private func present(newChat: Bool) {
        model.selectingModel = false
        // A global shortcut must not reset the draft behind an open file sheet.
        if let attachmentPicker { attachmentPicker.makeKeyAndOrderFront(nil); return }
        let start = ProcessInfo.processInfo.systemUptime
        settings?.orderOut(nil)
        let kept = model.summon(newChat: newChat)
        if !kept { fit(NSSize(width: model.panelWidth, height: 112)) }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        // A kept chat stays where it was being read, unless the pointer is on another display.
        if let screen, !kept || panel.screen?.frame != screen.frame {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2))
            if kept { fit(panel.frame.size) } // Clamp a tall thread to a smaller display.
        }
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        focusComposer(); panel.displayIfNeeded()
        metric(["kind": "show_layout", "kept": kept, "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
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
            window.minSize = NSSize(width: 520, height: 540)
            window.contentView = NSHostingView(rootView: ThemedView(model: model) { SettingsView(updater: updater, model: model) }); window.center(); settings = window
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    /// Agent mode's project folder, as a sheet on the panel like the attachment picker.
    private func showFolderPicker() {
        if let attachmentPicker { attachmentPicker.makeKeyAndOrderFront(nil); return }
        let picker = NSOpenPanel()
        picker.title = "Choose a project folder"; picker.prompt = "Use folder"
        picker.message = "The agent works in this folder."
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        attachmentPicker = picker
        NSApp.activate(ignoringOtherApps: true)
        let host = panel.isVisible ? panel! : (settings ?? panel!)
        picker.beginSheetModal(for: host) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.attachmentPicker = nil
                if result == .OK, let url = picker.url { self.model.addProject(path: url.path); self.model.agentMode = true }
                if host === self.panel { self.panel.makeKeyAndOrderFront(nil); self.focusComposer() }
            }
        }
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { summon(); return true }
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
