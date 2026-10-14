import AppKit
import SwiftUI
import Carbon
import Security

// Deliberately a spike: one model, no history persistence or attachment support.
@MainActor final class ChatModel: ObservableObject {
    @Published var draft = ""
    @Published var response = ""
    @Published var inputHeight: CGFloat = 120
    @Published var streaming = false
    @Published var error: String?
    var resize: (() -> Void)?
    var task: Task<Void, Never>?
    var generation = UUID()

    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        draft = ""; response = ""; streaming = false; error = nil; inputHeight = 120
        resize?()
    }

    func send() {
        guard !streaming, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = draft; draft = ""; response = ""; error = nil; streaming = true
        inputHeight = 120; resize?()
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            let start = ProcessInfo.processInfo.systemUptime
            var first: Double?; var count = 0
            do {
                let key = try apiKey()
                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "gpt-6.1-sol", "stream": true,
                    "reasoning": ["effort": "low"],
                    "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]]
                ])
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (bytes, reply) = try await session.bytes(for: request)
                guard let http = reply as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "OpenAI", code: (reply as? HTTPURLResponse)?.statusCode ?? 0,
                                  userInfo: [NSLocalizedDescriptionKey: "OpenAI rejected the request. Check key and model access."])
                }
                var completed = false
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard current == generation else { return }
                    guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                          let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if event["type"] as? String == "response.output_text.delta", let text = event["delta"] as? String {
                        if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                        count += 1; response += text; resize?()
                    }
                    if event["type"] as? String == "response.completed" { completed = true; break }
                    if ["error", "response.failed", "response.incomplete"].contains(event["type"] as? String ?? "") {
                        throw NSError(domain: "OpenAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenAI stream did not complete."])
                    }
                }
                guard completed else { throw NSError(domain: "OpenAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stream disconnected."]) }
                metric(["kind": "stream", "ttft_ms": first ?? -1, "total_ms": (ProcessInfo.processInfo.systemUptime-start)*1000, "deltas": count])
            } catch is CancellationError {
            } catch { if current == generation { self.error = error.localizedDescription } }
            if current == generation { streaming = false; resize?() }
        }
    }
}

func apiKey() throws -> String {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "com.boltbar.keys",
                               kSecAttrAccount as String: "openai", kSecReturnData as String: true,
                               kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
       let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty { return key }
    if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
    throw NSError(domain: "Boltbar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No OpenAI key found in Keychain or environment."])
}

func metric(_ values: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text); fflush(stdout)
}

final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class InputTextView: NSTextView {
    var send: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": paste(nil); return
            case "a": selectAll(nil); return
            case "c": copy(nil); return
            case "x": cut(nil); return
            default: break
            }
        }
        if event.keyCode == 53 { window?.orderOut(nil); return }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { send?(); return }
        super.keyDown(with: event)
    }
}

struct GrowingInput: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); let text = InputTextView(frame: NSRect(x: 0, y: 0, width: 816, height: 120))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = text
        text.isRichText = false; text.drawsBackground = false; text.textColor = .white
        text.font = .systemFont(ofSize: 15); text.textContainerInset = NSSize(width: 2, height: 4)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator; text.send = { model.send() }
        text.setAccessibilityLabel("Message")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? InputTextView else { return }
        if text.string != model.draft { text.string = model.draft }
        scroll.hasVerticalScroller = model.inputHeight >= 280
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ChatModel
        init(_ model: ChatModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView,
                  let layout = text.layoutManager, let container = text.textContainer else { return }
            model.draft = text.string; layout.ensureLayout(for: container)
            model.inputHeight = min(280, max(120, ceil(layout.usedRect(for: container).height + 16)))
            model.resize?()
        }
    }
}

struct Bar: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("BOLTBAR · SWIFT SPIKE"); Spacer(); Text("⌥ SPACE · ESC") }
                .font(.system(size: 11, weight: .medium)).tracking(1.3).foregroundStyle(.gray)
            if !model.response.isEmpty || model.streaming {
                ScrollView { Text(model.response.isEmpty ? "Thinking…" : model.response)
                    .font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 160)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text("Ask anything — a new conversation starts each time")
                    .foregroundStyle(.gray).font(.system(size: 15)).padding(.top, 4).padding(.leading, 7) }
                GrowingInput(model: model)
            }.frame(height: model.inputHeight)
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 18)).frame(width: 36, height: 36)
                    .background(.white.opacity(0.06), in: Circle()).foregroundStyle(.gray)
                    .accessibilityLabel("Attachments are outside the spike scope")
                Text("Low · GPT-6.1 Sol").font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 36).background(.white.opacity(0.06), in: Capsule())
                Spacer()
                Button { if model.streaming { model.task?.cancel() } else { model.send() } } label: {
                    Image(systemName: model.streaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .medium)).frame(width: 36, height: 36)
                        .background(Color(red: 0.96, green: 0.73, blue: 0.26), in: Circle()).foregroundStyle(.black)
                }.buttonStyle(.plain).accessibilityLabel(model.streaming ? "Stop" : "Send")
            }
        }.padding(18).background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 22)).preferredColorScheme(.dark)
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let model = ChatModel()
    var panel: ChatPanel!
    var hotkey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var status: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let newItem = appMenu.addItem(withTitle: "New chat", action: #selector(show), keyEquivalent: "n")
        newItem.target = self
        appMenu.addItem(withTitle: "Quit Swift spike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 852, height: 224),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 13, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.contentView = NSHostingView(rootView: Bar(model: model))
        model.resize = { [weak self] in self?.resizePanel() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "ϟS"
        let menu = NSMenu()
        let showItem = menu.addItem(withTitle: "New chat", action: #selector(show), keyEquivalent: "")
        showItem.target = self
        menu.addItem(withTitle: "Quit Swift spike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<Delegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.show() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let code = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x42425350, id: 1),
                                      GetApplicationEventTarget(), 0, &hotkey)
        metric(["kind": "hotkey", "status": code])
        if code != noErr { model.error = "Shortcut unavailable (\(code)). Quit Tauri before testing the spike." }
        show()
    }
    func resizePanel() {
        guard panel != nil else { return }
        var frame = panel.frame
        frame.size.height = 224 + model.inputHeight - 120 + ((!model.response.isEmpty || model.streaming) ? 172 : 0) + (model.error == nil ? 0 : 32)
        // AppKit origin is bottom-left: keeping origin fixed grows upward.
        panel.setFrame(frame, display: true)
    }
    @objc func show() {
        let start = ProcessInfo.processInfo.systemUptime
        model.reset(); resizePanel()
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        func focus(_ view: NSView) {
            if let text = view as? InputTextView { panel.makeFirstResponder(text) }
            else { view.subviews.forEach(focus) }
        }
        if let view = panel.contentView { focus(view) }
        panel.displayIfNeeded()
        metric(["kind": "show_layout", "ms": (ProcessInfo.processInfo.systemUptime-start)*1000])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
}

@main struct BoltbarSpike {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
    }
}
