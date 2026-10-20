import AppKit
import SwiftUI

// MARK: - Permission light

extension AgentPermission {
    /// A traffic light read as risk: gray only looks, green asks, amber edits, red acts freely.
    func color(_ theme: ThemePalette) -> Color {
        switch self {
        case .look: return Color(nsColor: NSColor(hex: "8E8E93")!)
        case .ask: return Color(nsColor: NSColor(hex: theme.dark ? "A0CCB8" : "39735C")!)
        case .edit: return Color(nsColor: NSColor(hex: theme.dark ? "E5BB88" : "986020")!)
        case .full: return theme.error
        }
    }
}

struct PermissionDot: View {
    @Environment(\.boltbarTheme) private var theme
    let permission: AgentPermission
    var body: some View {
        Circle().fill(permission.color(theme)).frame(width: 7, height: 7).accessibilityLabel("\(permission.title) permission")
    }
}

// MARK: - Agent chip

/// Off: a terminal button. On: the same button, which turns it off, joined to the project and its
/// permission light, which open the picker. The arrows change it in place; only a click opens the popover.
struct AgentChip: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    @State private var hoveringSwitch = false
    @State private var hoveringProject = false
    var body: some View {
        let shortcut = model.agentSettings.shortcut.label
        if model.agentMode, let project = model.agentProject {
            HStack(spacing: 0) {
                Button { model.toggleAgentMode() } label: {
                    Image(systemName: "apple.terminal").font(.system(size: 12, weight: .medium))
                        .padding(.leading, 11).padding(.trailing, 6).frame(maxHeight: .infinity)
                        .background(hoveringSwitch ? theme.text.opacity(0.08) : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { hoveringSwitch = $0 }
                    .accessibilityLabel("Turn off agent mode").help("Turn off agent mode · \(shortcut)")
                Button { model.selectingModel = false; model.showingModelPicker = false; model.showingAgentPicker.toggle() } label: {
                    HStack(spacing: 7) {
                        Text(model.agentSettings.displayName(project)).lineLimit(1).truncationMode(.middle)
                        PermissionDot(permission: project.permission)
                        if model.selectingAgent { hint(project).fixedSize() }
                    }
                    .padding(.leading, 5).padding(.trailing, 11).frame(maxHeight: .infinity)
                    .background(hoveringProject ? theme.text.opacity(0.06) : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { hoveringProject = $0 }
                    .accessibilityLabel("Agent project").accessibilityValue("\(project.name), \(project.permission.title)")
                    .help("Works in \(project.displayPath) · \(project.permission.title) · click to change")
                    .popover(isPresented: $model.showingAgentPicker, arrowEdge: .top) { AgentPopover(model: model) }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(theme.accent)
            .frame(height: 29).background(theme.surface).clipShape(Capsule())
            .overlay(Capsule().stroke(model.selectingAgent ? theme.accent : .clear, lineWidth: 1.5))
            .layoutPriority(1) // Its hints win over the empty drag area beside it.
        } else {
            // Reached with Tab it says how to turn on; the arrows do nothing here.
            Button { model.toggleAgentMode() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "apple.terminal").font(.system(size: 14))
                    if model.selectingAgent { Text("↵ turn on").font(.system(size: 12, weight: .medium, design: .monospaced)).fixedSize() }
                }
                .foregroundStyle(model.selectingAgent ? theme.accent : .secondary)
                .padding(.horizontal, model.selectingAgent ? 11 : 0).frame(minWidth: 30).frame(height: 30)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().stroke(model.selectingAgent ? theme.accent : .clear, lineWidth: 1.5))
            }.buttonStyle(.plain).accessibilityLabel("Agent mode").accessibilityValue("Off")
                .help("Agent mode: let the model act in a folder (\(shortcut))")
        }
    }
    /// While the chip has the keys: the level by name, or what the next press will do.
    @ViewBuilder private func hint(_ project: AgentProject) -> some View {
        if model.pendingProjectRemoval == project.id {
            Text("⌫ again removes").foregroundStyle(theme.error)
        } else if model.pendingFullAccess == project.id {
            Text("→ again for full").foregroundStyle(AgentPermission.full.color(theme))
        } else {
            Text(project.permission.title.lowercased()).foregroundStyle(project.permission.color(theme))
        }
    }
}

struct AgentPopover: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    @State private var hovered: UUID?
    var body: some View {
        let settings = model.agentSettings
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Project").font(.system(size: 12, weight: .medium, design: .monospaced)); Spacer(); Text("↑ ↓").foregroundStyle(.secondary) }
                .font(.system(size: 11, design: .monospaced))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(settings.projects) { project in
                    let selected = project.id == settings.selectedProject?.id
                    let removing = model.pendingProjectRemoval == project.id
                    HStack(spacing: 8) {
                        PermissionDot(permission: project.permission)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.displayName(project)).lineLimit(1)
                            Text(removing ? "Press ⌫ again to remove from the list" : project.displayPath)
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(removing ? theme.error : .secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if let left = settings.fullAccessRemaining(project) {
                            Text("full · \(Int((left / 3600).rounded(.up))) h").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if hovered == project.id && settings.projects.count > 1 {
                            Button { model.removeProject(project.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from the list (the folder is untouched)")
                        } else if selected { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                    }
                    .font(.system(size: 12, design: .monospaced)).padding(.vertical, 6).padding(.horizontal, 6)
                    .background(selected ? theme.text.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle()).onTapGesture { model.selectProject(project.id) }
                    .onHover { hovered = $0 ? project.id : (hovered == project.id ? nil : hovered) }
                }
                Button { model.chooseProjectFolder() } label: {
                    HStack { Image(systemName: "plus"); Text("Add folder…"); Spacer(); Text("or drop one on the bar").foregroundStyle(.secondary) }
                        .font(.system(size: 11, design: .monospaced)).padding(.vertical, 6).padding(.horizontal, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
            HStack { Text("Permission").font(.system(size: 12, weight: .medium, design: .monospaced)); Spacer(); Text("← →").foregroundStyle(.secondary) }
                .font(.system(size: 11, design: .monospaced))
            if let project = settings.selectedProject {
                HStack(spacing: 3) {
                    ForEach(AgentPermission.allCases, id: \.self) { level in
                        Button { model.choosePermission(level, for: project.id) } label: {
                            HStack(spacing: 6) { PermissionDot(permission: level); Text(level.title) }
                                .font(.system(size: 12, weight: .medium, design: .monospaced)).frame(maxWidth: .infinity).padding(.vertical, 7)
                                .foregroundStyle(project.permission == level ? theme.text : theme.text.opacity(0.55))
                                .background(project.permission == level ? theme.text.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityAddTraits(project.permission == level ? .isSelected : [])
                    }
                }.padding(3).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                if model.pendingFullAccess == project.id {
                    Text(fullWarning(settings)).font(.system(size: 10, design: .monospaced)).foregroundStyle(AgentPermission.full.color(theme))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(project.permission.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            if let session = model.agentSession {
                Button { model.copyTerminalCommand(); model.showingAgentPicker = false } label: {
                    HStack(spacing: 8) {
                        Text("Continue in terminal")
                        Spacer(minLength: 8)
                        Text(session.provider == .anthropic ? "claude --resume" : "codex resume").foregroundStyle(.secondary)
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }.font(.system(size: 11, design: .monospaced)).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Copies \(session.terminalCommand)")
            }
            Button { model.toggleAgentMode() } label: {
                HStack { Text("Turn off agent mode"); Spacer(); Text(settings.shortcut.label).foregroundStyle(.secondary) }
                    .font(.system(size: 11, design: .monospaced)).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(14).frame(width: 320).background(theme.background)
    }
    private func fullWarning(_ settings: AgentSettings) -> String {
        let lasts = settings.fullAccessExpires ? "for 24 hours" : "until you change it"
        return "Full runs any command and changes any file without asking, \(lasts). Press → or click Full again to turn it on."
    }
}

// MARK: - Unrolling tools

/// [+] unrolls web search and history on hover; an active state stays pinned in view.
struct ToolRoll: View {
    @Environment(\.boltbarTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ChatModel
    @State private var open = false
    @State private var intent: DispatchWorkItem?
    var body: some View {
        HStack(spacing: 6) {
            Button { model.pickFiles() } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium)).rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 30, height: 30).background(theme.surface, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Attach files").help("Attach images, PDFs or text files")
            if open || model.webSearchActive { globe.transition(.opacity.combined(with: .move(edge: .leading))) }
            if open { history.transition(.opacity.combined(with: .move(edge: .leading))) }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            intent?.cancel()
            let work = DispatchWorkItem { withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) { open = hovering } }
            intent = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? 0.12 : 0.4), execute: work)
        }
    }
    private var globe: some View {
        Button { model.webSearch.toggle() } label: {
            Image(systemName: "globe").font(.system(size: 15))
                .foregroundStyle(model.webSearchActive ? theme.accent : .secondary)
                .frame(width: 30, height: 30).background(model.webSearchActive ? theme.accent.opacity(0.12) : .clear, in: Circle())
        }.buttonStyle(.plain).disabled(!model.canSearchWeb || model.streaming || model.agentMode)
            .accessibilityLabel("Search the web").accessibilityValue(model.webSearchActive ? "On" : "Off")
            .help(model.agentMode ? "Web search is off in agent mode" : model.canSearchWeb ? (model.webSearch ? "Web access on · searches when needed" : "Allow web search · remembers your choice") : "Web search with Codex requires an OpenAI API key")
    }
    private var history: some View {
        Button { model.showingModelPicker = false; model.showHistory() } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 30, height: 30)
        }.buttonStyle(.plain).help("Previous chats (→ when the message is empty)").accessibilityLabel("Previous chats")
    }
}

// MARK: - Steps and approvals

/// One line per action, so the model's own words stay the main thing.
struct AgentStepList: View {
    @Environment(\.boltbarTheme) private var theme
    let steps: [AgentStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    icon(step).frame(width: 14)
                    Text(step.title).lineLimit(1).truncationMode(.middle).strikethrough(step.status == .denied)
                        .foregroundStyle(step.status == .running ? theme.text : theme.text.opacity(0.75))
                    if let detail = step.status == .denied ? "declined" : step.detail {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 12, design: .monospaced))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func icon(_ step: AgentStep) -> some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: step.kind == .edit ? "pencil" : "checkmark").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark").foregroundStyle(theme.error)
        case .denied: Image(systemName: "nosign").foregroundStyle(.secondary)
        }
    }
}

/// Inline, in the queue's place: never a modal, and never answered by a stray Return.
struct ApprovalCard: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    let request: ApprovalRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(request.action).foregroundStyle(.secondary)
                Text(request.subject).foregroundStyle(theme.accent).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Text("in " + URL(fileURLWithPath: request.directory).lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }.font(.system(size: 12, design: .monospaced))
            HStack(spacing: 8) {
                button("Allow", "⌘↵") { model.resolveApproval(.allow) }
                button("Allow in this chat", "⌥⌘↵") { model.resolveApproval(.allowForChat) }
                button("Deny", "esc") { model.resolveApproval(.deny) }
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel("Permission request: \(request.action) \(request.subject)")
    }
    private func button(_ title: String, _ keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(title); Text(keys).foregroundStyle(.secondary) }
                .font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 8).frame(height: 22)
                .background(theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}

// MARK: - Commands and help

struct SlashMenu: View {
    @Environment(\.boltbarTheme) private var theme
    let matches: [(command: String, summary: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(matches.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 10) {
                    Text(item.command).foregroundStyle(index == 0 ? theme.accent : theme.text)
                    Text(item.summary).foregroundStyle(.secondary)
                    Spacer()
                    if index == 0 { Text("tab").foregroundStyle(.secondary) }
                }.font(.system(size: 12, design: .monospaced))
            }
        }.padding(.horizontal, 10).padding(.vertical, 6).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HelpPane: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.closeHelp() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }.buttonStyle(.plain).accessibilityLabel("Close help")
                Text("Boltbar help").font(.system(size: 14, weight: .semibold, design: .monospaced))
                Spacer()
                Text("esc closes").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            ScrollView { MarkdownText(source: HelpContent.markdown(model.agentSettings.shortcut.label)).padding(.trailing, 6) }
                .frame(height: 360)
        }
    }
}

enum HelpContent {
    static let commands: [(command: String, summary: String)] = [
        ("/help", "Everything about Boltbar"), ("/new", "Start a new chat"), ("/agent", "Turn agent mode on or off"),
        ("/terminal", "Copy the command that continues this agent chat in a terminal"),
    ]
    static func markdown(_ agentShortcut: String) -> String {
        """
        ## Everyday keys
        | Keys | What it does |
        |---|---|
        | ⌥ Space | Open Boltbar over any app. If a reply is still coming, it returns where you left it |
        | ↵ | Send. While a reply streams, queue your next message |
        | ⇧ ↵ | New line |
        | Esc | Hide the bar |
        | ⌘ N | New chat |
        | ⌘ , | Settings |
        | ⌘ ? | This help, also /help |

        ## Models and effort
        With an empty message, ↑ ↓ switch model and outline its chip. While outlined, ← → set the thinking effort. Click the chip for the full list.

        ## While it answers
        Keep typing: ↵ adds your message to a queue above the field, and the queue goes out when the reply ends. ↵ on an empty field, or Send now, interrupts the reply and sends the queue at once. Stop keeps the partial reply, marked Interrupted.

        ## Previous chats
        → with an empty message, or the clock, opens your chats. Type to search titles and every message; ↑ ↓ select, → or ↵ open, ← goes back to the same search, ⌫ twice deletes.

        ## Agent mode
        \(agentShortcut) or the terminal button lets the model act in a project folder through Claude Code or Codex. The chip shows where it works and its permission light:
        - Gray, Look: reads files and runs read-only commands, never changes anything.
        - Green, Ask: asks before every command or change.
        - Amber, Edit: changes files in the project without asking, deletes included, and asks before other commands or changes outside it.
        - Red, Full: runs any command and changes any file without asking. It takes a second → or click, and returns to Ask after 24 hours unless you turn that off in Settings.

        Each project remembers its permission. With an empty message, Tab outlines the model chip, Tab again the agent chip, and ⇧Tab goes back. ↵ on the agent chip turns agent mode on or off, as does a click on the terminal icon. On the agent chip, ↑ ↓ change project, ← → change permission, ⌫ twice removes a project from the list (the folder is untouched); click it for the full list. Drop a folder on the bar to add it; the first project is your Documents folder.

        It follows the project's own rules: Claude Code reads CLAUDE.md, or AGENTS.md when there is none, and Codex the other way round.

        Each agent chat is a real Claude Code session or Codex thread, so later messages continue it and you can pick it up in a terminal: /terminal, or Continue in terminal in the agent chip, copies the command. Switching project or CLI, or retrying a reply, starts a new session. Deleting a chat in Boltbar leaves the CLI's copy.

        When it asks, ⌘↵ allows, ⌥⌘↵ allows the same thing for the rest of the chat, and Esc denies. Stop denies anything still waiting. Web search is off in agent mode.

        ## Commands
        | Command | What it does |
        |---|---|
        | /help | This help |
        | /new | Start a new chat |
        | /agent | Turn agent mode on or off |
        | /terminal | Copy the command that continues this agent chat in a terminal |

        ## Attachments and web
        Paste, drop or pick images, PDFs and text files; they stay with the message for follow-ups. Hover + for the globe, which lets the model search the web with numbered sources, and your previous chats.

        ## Privacy
        API keys stay in the Keychain. Chats and attachments stay on your Mac. Boltbar talks to the provider you choose and to GitHub for signed updates; there are no analytics. A supporter license is checked on your Mac, never online.
        """
    }
}
