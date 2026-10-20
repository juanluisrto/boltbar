import AppKit
import Carbon
import SwiftUI

struct SettingsSection<Content: View>: View {
    @Environment(\.boltbarTheme) private var theme
    var title: String?
    let content: Content
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold, design: .monospaced)) }
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
        }
    }
}

struct ProviderSettings: View {
    @ObservedObject var model: ChatModel
    let provider: Provider
    @State private var key = ""
    @State private var notice: String?
    var body: some View {
        SettingsSection(title: provider.title) {
            Text(model.catalogs[provider]?.detail ?? "Checking…").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            InterfacePicker(label: "Connection", selection: Binding(get: { model.preferences.transport(provider) }, set: {
                model.preferences.transports[provider.rawValue] = $0
                Task { await model.refresh() }
            }), options: Transport.allCases, title: { $0.title })
            Group {
                Button("Allow access to saved key") {
                    Task {
                        do {
                            let key = try await Task.detached { try Keychain.read(provider, allowInteraction: true) }.value
                            notice = key == nil ? "No saved key for this provider." : "Keychain access approved."; await model.refresh()
                        } catch { notice = error.localizedDescription }
                    }
                }
                HStack {
                    SecureField("\(provider.title) API key", text: $key).font(.system(size: 12, design: .monospaced))
                    Button("Save to Keychain") {
                        do { try Keychain.save(key, for: provider); key = ""; notice = "Saved in macOS Keychain."; Task { await model.refresh() } }
                        catch { notice = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let notice { Text(notice).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack {
                Text(provider.loginCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy login command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(provider.loginCommand, forType: .string) }
            }
            Text("Run this in Terminal to sign in. Boltbar reuses the official CLI session; it never copies or refreshes its login tokens.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Appearance") {
                InterfacePicker(label: "Mode", selection: $model.appearance.mode, options: AppearanceMode.allCases, title: { $0.title })
                InterfacePicker(label: "Light theme", selection: Binding(get: { model.appearance.lightTheme }, set: { model.appearance.selectTheme($0) }), options: ThemeName.allCases.filter { !$0.isDark }, title: { $0.title })
                InterfacePicker(label: "Dark theme", selection: Binding(get: { model.appearance.darkTheme }, set: { model.appearance.selectTheme($0) }), options: ThemeName.allCases.filter(\.isDark), title: { $0.title })
                HStack {
                    Text("Accent color")
                    Spacer()
                    ColorPicker("Accent color", selection: Binding(get: { theme.accent }, set: {
                        model.appearance.customAccent = NSColor($0).rgbHex
                    }), supportsOpacity: false).labelsHidden()
                }
                if model.appearance.customAccent != nil {
                    Button("Use theme accent") { model.appearance.customAccent = nil }
                }
                Text("System switches between your preferred light and dark themes automatically.")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection(title: "Defaults") {
                InterfacePicker(label: "Model", selection: $model.defaultModel, options: [ModelChoice?.none] + model.selectableModels.map { Optional($0) }, title: { $0.map { modelTitle($0.model) } ?? "Latest used" })
                InterfacePicker(label: "Thinking effort", selection: $model.preferences.effort, options: Effort.allCases, title: { $0.title })
                HStack { Text("Global shortcut"); Spacer(); ShortcutRecorder(model: model).frame(width: 180, height: 28) }
                Text("A summon starts a new conversation, or brings back the current one while a reply streams, messages are queued or a reply finished while the bar was hidden. Escape hides the bar; ⌘N always starts fresh; ⌘, opens Settings.").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ModelSettingsView(model: model)
            AgentSettingsView(model: model)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Connections").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Button(model.refreshing ? "Refreshing…" : "Refresh") { Task { await model.refresh() } }.disabled(model.refreshing)
                }
                ForEach(Provider.allCases) { ProviderSettings(model: model, provider: $0) }
            }
            UpdateSettings(updater: updater)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(.body, design: .monospaced)).buttonStyle(InterfaceButtonStyle())
            .frame(minWidth: 520, minHeight: 540).background(theme.background)
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
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.record = { model.updateShortcut?($0, $1, $2) ?? false }
        button.setAccessibilityLabel("Record global shortcut")
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) { if !button.recording { button.title = model.preferences.shortcutLabel } }
}

/// Agent mode: its shortcut, how long full access lasts, and the project folders.
struct AgentSettingsView: View {
    @ObservedObject var model: ChatModel
    var body: some View {
        SettingsSection(title: "Agent mode") {
            HStack { Text("Shortcut"); Spacer(); AgentShortcutRecorder(model: model).frame(width: 180, height: 28) }
            Toggle("Full access expires after 24 hours", isOn: $model.agentSettings.fullAccessExpires)
            Text("When it expires, later sessions in that project start at Ask.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text("Projects").font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.top, 4)
            ForEach(model.agentSettings.projects) { project in
                HStack(spacing: 10) {
                    PermissionDot(permission: project.permission)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.agentSettings.displayName(project))
                        Text(project.displayPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Picker("Permission", selection: Binding(get: { project.permission }, set: { model.setPermission($0, for: project.id) })) {
                        ForEach(AgentPermission.selectable, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 90)
                    Button("Remove") { model.removeProject(project.id) }.disabled(model.agentSettings.projects.count < 2)
                        .help("Removes it from Boltbar's list; the folder is untouched")
                }
            }
            Button("Add folder…") { model.chooseProjectFolder() }
            Text("The agent runs Claude Code or Codex in the selected project. Look only reads; Ask asks before every command or change. Web search is off in agent mode.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Records an in-app shortcut: ⌘ plus a key, optionally with ⇧ or ⌥, avoiding the ones Boltbar already uses.
final class AgentShortcutButton: NSButton {
    static let reserved: Set<String> = ["a", "c", "v", "x", "z", "n", ",", "q", "w", "h", "m", "/"]
    var record: ((AgentShortcut) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { recording = true; title = "Press ⌘ + key…"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = "Record shortcut"; return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command), !flags.contains(.control), let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
            title = "Use ⌘ with a key"; return
        }
        let shortcut = AgentShortcut(key: key, shift: flags.contains(.shift), option: flags.contains(.option))
        if !shortcut.shift && !shortcut.option && Self.reserved.contains(key) { title = "Used by Boltbar"; return }
        record?(shortcut); title = shortcut.label; recording = false
    }
}
struct AgentShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    func makeNSView(context: Context) -> AgentShortcutButton {
        let button = AgentShortcutButton(title: model.agentSettings.shortcut.label, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.record = { model.agentSettings.shortcut = $0 }
        button.setAccessibilityLabel("Record agent mode shortcut")
        return button
    }
    func updateNSView(_ button: AgentShortcutButton, context: Context) { if !button.recording { button.title = model.agentSettings.shortcut.label } }
}
