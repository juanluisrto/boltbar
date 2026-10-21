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
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    let provider: Provider
    @State private var key = ""
    @State private var notice: String?
    var body: some View {
        SettingsSection(title: provider.title) {
            status(provider.cliName, cli)
            status("API key", apiKey)
            if model.keyStatus[provider] == .needsAccess {
                Button("Allow access to saved key") {
                    Task {
                        do {
                            let key = try await Task.detached { try Keychain.read(provider, allowInteraction: true) }.value
                            notice = key == nil ? "No saved key for this provider." : "Keychain access approved."; await model.refresh()
                        } catch { notice = error.localizedDescription }
                    }
                }
            }
            HStack {
                SecureField(model.keyStatus[provider] == .saved ? "Replace the saved key" : "\(provider.title) API key", text: $key).font(.system(size: 12, design: .monospaced))
                Button("Save to Keychain") {
                    do { try Keychain.save(key, for: provider); key = ""; notice = "Saved in macOS Keychain."; Task { await model.refresh() } }
                    catch { notice = error.localizedDescription }
                }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let notice { Text(notice).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            InterfacePicker(label: "Connection", selection: Binding(get: { model.preferences.transport(provider) }, set: {
                model.preferences.transports[provider.rawValue] = $0
                Task { await model.refresh() }
            }), options: Transport.allCases, title: { $0.title })
            if let catalog = model.catalogs[provider] {
                Text(catalog.ready ? (catalog.live ? "Chats use the API key." : "Chats use \(provider.cliName).") : catalog.detail)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(catalog.ready ? theme.text.opacity(0.56) : theme.error)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
    /// The CLI's own answer, checked when Boltbar starts and on Refresh; Boltbar never touches its login.
    private var cli: (text: String, ok: Bool?) {
        switch model.cliStatus[provider] {
        case nil: return ("Checking…", nil)
        case .signedIn(let detail)?: return (["Signed in", detail].compactMap { $0 }.joined(separator: " "), true)
        case .signedOut?: return ("Not signed in", false)
        case .missing?: return ("Not installed", nil)
        case .failed(let message)?: return (message, false)
        }
    }
    private var apiKey: (text: String, ok: Bool?) {
        switch model.keyStatus[provider] {
        case nil: return ("Checking…", nil)
        case .saved?: return ("Saved in Keychain", true)
        case .none?: return ("None", nil)
        case .needsAccess?: return ("Saved, needs your approval", false)
        }
    }
    private func status(_ name: String, _ state: (text: String, ok: Bool?)) -> some View {
        HStack(spacing: 8) {
            Text(name)
            Spacer()
            if let ok = state.ok { Circle().fill(ok ? theme.accent : theme.error).frame(width: 7, height: 7) }
            Text(state.text).foregroundStyle(state.ok == true ? theme.text : theme.text.opacity(0.56)).lineLimit(1).truncationMode(.middle)
        }.accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    @FocusState private var licenseFieldFocused: Bool
    var body: some View {
        ScrollViewReader { proxy in
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
                HStack(spacing: 8) {
                    Text("Text size")
                    Spacer()
                    Button { model.appearance.stepTextSize(-1) } label: { Image(systemName: "minus").frame(width: 12, height: 12) }
                        .buttonStyle(InterfaceButtonStyle()).disabled(model.appearance.chatTextSize <= AppearancePreferences.textSizes.first!)
                        .accessibilityLabel("Smaller text").help("Smaller text · ⌘−")
                    Text("\(Int(model.appearance.chatTextSize)) pt").monospacedDigit().frame(minWidth: 46)
                    Button { model.appearance.stepTextSize(1) } label: { Image(systemName: "plus").frame(width: 12, height: 12) }
                        .buttonStyle(InterfaceButtonStyle()).disabled(model.appearance.chatTextSize >= AppearancePreferences.textSizes.last!)
                        .accessibilityLabel("Bigger text").help("Bigger text · ⌘+")
                }
                if model.appearance.textSize != nil {
                    Button("Use standard size") { model.appearance.stepTextSize(0) }
                }
                Text("System switches between your preferred light and dark themes automatically. Text size applies to every chat; in the bar ⌘+ and ⌘− change it and ⌘0 resets it.")
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
            LicenseSettings(model: model, fieldFocused: $licenseFieldFocused).id("license")
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { reveal(proxy) }.onChange(of: model.settingsTarget) { _ in reveal(proxy) }
        }.font(.system(.body, design: .monospaced)).buttonStyle(InterfaceButtonStyle())
            .frame(minWidth: 520, minHeight: 540).background(theme.background)
    }
    /// "Enter key" in the reminder opens Settings here, ready to paste.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let target = model.settingsTarget else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target, anchor: .top) }
            if target == "license" && model.license == nil { licenseFieldFocused = true }
            model.settingsTarget = nil
        }
    }
}

/// The supporter license: who it's for, or a place to paste one.
struct LicenseSettings: View {
    @ObservedObject var model: ChatModel
    var fieldFocused: FocusState<Bool>.Binding
    @State private var key = ""
    @State private var notice: String?
    var body: some View {
        SettingsSection(title: "License") {
            switch model.licenseState {
            case .licensed(let license):
                HStack {
                    Text("Licensed to \(license.name)")
                    Spacer()
                    Button("Remove license") {
                        do { try model.removeLicense(); notice = nil } catch { notice = error.localizedDescription }
                    }
                }
                Text([license.email, "order \(license.order)", license.issued].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            case .locked(let message):
                HStack {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Allow access to saved license") { Task { await model.loadLicense(allowInteraction: true) } }
                }
            case .checking, .unlicensed:
                HStack {
                    Text(model.licenseState == .checking ? "Checking…" : "Unlicensed")
                    Spacer()
                    Button("Lost your key?") { model.recoverLicense() }
                    Button("Buy a license…") { model.buyLicense() }
                }
            }
            if model.license == nil {
                HStack {
                    TextField("Paste your license key", text: $key).font(.system(size: 12, design: .monospaced))
                        .focused(fieldFocused).onSubmit(add)
                    Button("Add license", action: add).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let notice { Text(notice).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(model.license == nil
                 ? "Boltbar is MIT licensed and works fully without a license. A one-off supporter license keeps it going and silences the occasional reminder. Keys are checked on this Mac and kept in the Keychain; nothing is sent anywhere."
                 : "Thank you for supporting Boltbar. The key is checked on this Mac and kept in the Keychain; nothing is sent anywhere.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func add() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try model.enterLicense(key); key = ""; notice = nil } catch { notice = error.localizedDescription }
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
                        ForEach(AgentPermission.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 90)
                    Button("Remove") { model.removeProject(project.id) }.disabled(model.agentSettings.projects.count < 2)
                        .help("Removes it from Boltbar's list; the folder is untouched")
                }
            }
            Button("Add folder…") { model.chooseProjectFolder() }
            Text("The agent runs Claude Code or Codex in the selected project. Look only reads. Ask asks before every command or change. Edit changes files in the project freely and asks before other commands. Full never asks. Web search is off in agent mode.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Records an in-app shortcut: ⌘ plus a key, optionally with ⇧ or ⌥, avoiding the ones Boltbar already uses.
final class AgentShortcutButton: NSButton {
    static let reserved: Set<String> = ["a", "c", "v", "x", "z", "n", ",", "q", "w", "h", "m", "/"]
    /// The text-size keys, taken with or without ⇧.
    static let textSize: Set<String> = ["+", "=", "-", "0"]
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
        if !shortcut.shift && !shortcut.option && Self.reserved.contains(key) || !shortcut.option && Self.textSize.contains(key) { title = "Used by Boltbar"; return }
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
