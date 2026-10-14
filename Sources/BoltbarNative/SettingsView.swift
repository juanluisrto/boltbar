import AppKit
import Carbon
import SwiftUI

struct ProviderSettings: View {
    @ObservedObject var model: ChatModel
    let provider: Provider
    @State private var key = ""
    @State private var notice: String?
    var body: some View {
        Section(provider.title) {
            Text(model.catalogs[provider]?.detail ?? "Checking…").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Picker("Connection", selection: Binding(get: { model.preferences.transport(provider) }, set: {
                model.preferences.transports[provider.rawValue] = $0
                Task { await model.refresh() }
            })) {
                ForEach(Transport.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Default model", selection: Binding(get: { model.preferences.model(provider) }, set: { model.preferences.models[provider.rawValue] = $0 })) {
                ForEach(model.catalogs[provider]?.models ?? provider.defaults, id: \.self) { Text(modelTitle($0)).tag($0) }
            }
            if provider != .cursor {
                Button("Allow access to saved key") {
                    Task {
                        do {
                            let key = try await Task.detached { try Keychain.read(provider, allowInteraction: true) }.value
                            notice = key == nil ? "No saved key for this provider." : "Keychain access approved."; await model.refresh()
                        } catch { notice = error.localizedDescription }
                    }
                }
                HStack {
                    SecureField("\(provider.title) API key", text: $key)
                    Button("Save to Keychain") {
                        do { try Keychain.save(key, for: provider); key = ""; notice = "Saved in macOS Keychain."; Task { await model.refresh() } }
                        catch { notice = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack {
                Text(provider.loginCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy login command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(provider.loginCommand, forType: .string) }
            }
            Text("Run this in Terminal to sign in. Boltbar reuses the official CLI session; it never copies or refreshes its login tokens.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Provider", selection: $model.preferences.provider) { ForEach(Provider.allCases) { Text($0.title).tag($0) } }
                Picker("Thinking effort", selection: $model.preferences.effort) { ForEach(Effort.allCases, id: \.self) { Text($0.title).tag($0) } }
                HStack { Text("Global shortcut"); Spacer(); ShortcutRecorder(model: model).frame(width: 180, height: 28) }
                Text("Every summon starts a new conversation. Escape hides the bar; ⌘N starts fresh; ⌘, opens Settings.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Provider.allCases) { ProviderSettings(model: model, provider: $0) }
            Section {
                Button(model.refreshing ? "Refreshing…" : "Refresh logins and models") { Task { await model.refresh() } }.disabled(model.refreshing)
                Text("Keys: macOS Keychain, service com.boltbar.keys. Conversations and attachments stay in memory. They are sent only to the selected provider when you press Send.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("API transports stream text fragments and support images/PDFs. CLI transports accept text documents; Codex exec currently returns complete message events.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped).frame(minWidth: 520, minHeight: 540).preferredColorScheme(.dark)
    }
}

final class ShortcutButton: NSButton {
    var record: ((UInt32, UInt32, String) -> Bool)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = "Record shortcut"; return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { title = "Use ⌘, ⌃ or ⌥"; return }
        var carbon: UInt32 = 0, label = ""
        for (flag, value, symbol): (NSEvent.ModifierFlags, Int, String) in [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { carbon |= UInt32(value); label += symbol }
        }
        label += event.keyCode == 49 ? " Space" : (event.charactersIgnoringModifiers ?? "Key \(event.keyCode)").uppercased()
        if record?(UInt32(event.keyCode), carbon, label) == true { title = label; recording = false }
        else { title = "Shortcut in use" }
    }
}
struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton(title: model.preferences.shortcutLabel, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.record = { model.updateShortcut?($0, $1, $2) ?? false }
        button.setAccessibilityLabel("Record global shortcut")
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) { if !button.recording { button.title = model.preferences.shortcutLabel } }
}
