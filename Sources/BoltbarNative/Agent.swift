import Foundation

// Agent mode: the official CLIs act in a project folder, and Boltbar answers
// their permission requests. Claude Code sends `can_use_tool` control requests
// over stdio; Codex's app-server sends approval requests over JSON-RPC.

/// How much the agent may do without asking. Look and Ask ship first.
enum AgentPermission: String, Codable, CaseIterable {
    case look, ask, edit, full
    var title: String { rawValue.capitalized }
    var summary: String {
        switch self {
        case .look: return "Reads files and runs read-only commands; never changes anything"
        case .ask: return "Asks before every command or change"
        case .edit: return "Changes files in the project without asking, deletes included; asks before other commands"
        case .full: return "Runs any command and changes any file without asking"
        }
    }
}

struct AgentProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var permission: AgentPermission = .ask
    /// When full access was granted; it returns to Ask after a day unless disabled in Settings.
    var fullSince: Date?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// An in-app shortcut: a key with ⌘ and optional ⇧ or ⌥.
struct AgentShortcut: Codable, Equatable {
    var key = "j"
    var shift = false
    var option = false
    var label: String { "⌘" + (option ? "⌥" : "") + (shift ? "⇧" : "") + key.uppercased() }
}

struct AgentSettings: Codable, Equatable {
    static let fullAccessLifetime: TimeInterval = 24 * 60 * 60
    var projects: [AgentProject] = [AgentProject(path: NSHomeDirectory() + "/Documents")]
    var selected: UUID?
    var fullAccessExpires = true
    var shortcut = AgentShortcut()

    var selectedProject: AgentProject? { projects.first { $0.id == selected } ?? projects.first }
    /// Folder names repeat (two "api" folders); show the parent too when they do.
    func displayName(_ project: AgentProject) -> String {
        guard projects.filter({ $0.name == project.name }).count > 1 else { return project.name }
        return URL(fileURLWithPath: project.path).deletingLastPathComponent().lastPathComponent + "/" + project.name
    }
    /// Full access lasts a day; later sessions in that project start at Ask.
    @discardableResult mutating func expireFullAccess(now: Date = Date()) -> Bool {
        guard fullAccessExpires else { return false }
        var changed = false
        for index in projects.indices where projects[index].permission == .full {
            if now.timeIntervalSince(projects[index].fullSince ?? .distantPast) >= Self.fullAccessLifetime {
                projects[index].permission = .ask; projects[index].fullSince = nil; changed = true
            }
        }
        return changed
    }
    func fullAccessRemaining(_ project: AgentProject, now: Date = Date()) -> TimeInterval? {
        guard fullAccessExpires, project.permission == .full, let since = project.fullSince else { return nil }
        return max(0, Self.fullAccessLifetime - now.timeIntervalSince(since))
    }
}

/// One thing the agent did, shown as a single line in the reply.
struct AgentStep: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case command, read, edit, search, tool }
    enum Status: String, Codable { case running, done, failed, denied }
    let id: String
    var kind: Kind
    var title: String
    var status: Status = .running
    var detail: String?
}

struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    /// "Run" or "Edit", followed by `subject`.
    let action: String
    let subject: String
    let directory: String
    /// Identifies the same request again for "allow in this chat".
    var key: String { action + "\u{1F}" + subject }
}
enum ApprovalDecision { case allow, allowForChat, deny }

/// What an agent turn needs from the app.
struct AgentTurn {
    let directory: String
    let permission: AgentPermission
    let approve: @MainActor @Sendable (ApprovalRequest) async -> ApprovalDecision
}

enum Agent {
    static func instructions(_ directory: String, for provider: Provider) -> String {
        let base = "You are running inside Boltbar, a small chat bar on the user's Mac. You are working in \(directory). " +
            "Act on the user's request with your tools, keep your replies short, and say what you changed. " +
            "The input contains the conversation so far, with role labels; answer the latest user message."
        return projectRules(directory, for: provider).map { base + "\n\n" + $0 } ?? base
    }
    /// The project's own rules. Claude Code runs in safe mode, which skips CLAUDE.md, so Boltbar passes it on,
    /// or AGENTS.md when there is none. Codex reads AGENTS.md itself and gets CLAUDE.md only when there is none.
    static func projectRules(_ directory: String, for provider: Provider) -> String? {
        let present = { (names: [String]) in
            names.filter { name in
                var folder: ObjCBool = false
                return FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &folder) && !folder.boolValue
            }
        }
        let claude = present(["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"]), agents = present(["AGENTS.md"])
        let files = provider == .anthropic ? (claude.isEmpty ? agents : claude) : (agents.isEmpty && present(["AGENTS.override.md"]).isEmpty ? claude : [])
        var budget = 40_000
        let parts = files.compactMap { name -> String? in
            guard budget > 0, let text = try? String(contentsOfFile: (directory as NSString).appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let kept = text.count > budget ? String(text.prefix(budget)) + "\n[…the rest of this file was cut]" : text
            budget -= kept.count
            return "<project_instructions file=\"\(name)\">\n\(kept)\n</project_instructions>"
        }
        guard !parts.isEmpty else { return nil }
        return "The project keeps its own instructions for coding agents. Follow them unless the user asks otherwise.\n\n" + parts.joined(separator: "\n\n")
    }
    static func stream(_ request: ChatRequest, agent: AgentTurn, update: @escaping (StreamUpdate) async -> Void) async throws {
        guard FileManager.default.fileExists(atPath: agent.directory) else {
            throw AppError("The project folder \(agent.directory) is missing. Choose another one in the agent chip.")
        }
        if request.provider == .anthropic { try await ClaudeAgent.stream(request, agent: agent, update: update) }
        else { try await CodexAgent.stream(request, agent: agent, update: update) }
    }
    /// A path shown relative to the project, as people read it.
    static func relative(_ path: String, to directory: String) -> String {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
    /// Whether a path the agent wants to change lies in the project folder.
    static func contains(_ directory: String, _ path: String) -> Bool {
        let base = URL(fileURLWithPath: directory).standardizedFileURL.path
        let target = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
    static func shorten(_ text: String, _ limit: Int = 90) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

// MARK: - Claude Code

/// Claude Code in stream-json mode, with permission prompts answered by Boltbar.
enum ClaudeAgent {
    static func arguments(_ request: ChatRequest, agent: AgentTurn) -> [String] {
        var args = ["-p", "--verbose", "--include-partial-messages", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--model", request.model, "--effort", request.effort.rawValue,
                    // Web content plus tools is how data leaves a machine; keep it out of agent mode for now.
                    "--disallowedTools", "WebSearch,WebFetch",
                    "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--safe-mode", "--no-session-persistence",
                    "--append-system-prompt", Agent.instructions(agent.directory, for: .anthropic)]
        switch agent.permission {
        case .look: args += ["--permission-mode", "manual", "--permission-prompts", "none"]
        case .ask: args += ["--permission-mode", "manual", "--permission-prompt-tool", "stdio"]
        case .edit: args += ["--permission-mode", "acceptEdits", "--permission-prompt-tool", "stdio"]
        case .full: args += ["--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions"]
        }
        return args
    }

    static func stream(_ request: ChatRequest, agent: AgentTurn, update: @escaping (StreamUpdate) async -> Void) async throws {
        let content = try CLIInput.blocks(request, codex: false)
        let child = try LineProcess(program: CLI.program(.anthropic), args: arguments(request, agent: agent), keepInputOpen: true,
                                    directory: agent.directory)
        defer { child.cancel() }
        try await withTaskCancellationHandler {
            try await child.send(["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull()])
            var parser = ClaudeAgentStream(directory: agent.directory)
            for try await line in child.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if event["type"] as? String == "control_request", let id = event["request_id"] {
                    let response = await parser.answer(event["request"] as? [String: Any] ?? [:], approve: agent.approve)
                    try await child.send(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
                    continue
                }
                for item in try parser.consume(event) { await update(item) }
                if parser.completed { return }
            }
            throw AppError("The Claude CLI connection ended before the response completed.")
        } onCancel: { child.cancel() }
    }
}

/// Turns Claude Code events into text and steps, and permission requests into approvals.
struct ClaudeAgentStream {
    let directory: String
    private var text = ClaudeChatStream()
    private var steps: [String: AgentStep] = [:]
    private var denied: Set<String> = []
    private var afterStep = false
    private var saidSomething = false
    private(set) var completed = false
    init(directory: String) { self.directory = directory }

    mutating func consume(_ event: [String: Any]) throws -> [StreamUpdate] {
        var out: [StreamUpdate] = []
        let type = event["type"] as? String
        if type == "assistant", let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            for block in content where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, steps[id] == nil else { continue }
                let step = Self.step(id: id, tool: block["name"] as? String ?? "Tool", input: block["input"] as? [String: Any] ?? [:], directory: directory)
                steps[id] = step; out.append(.step(step)); afterStep = true
            }
        }
        if type == "user", let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, var step = steps[id] else { continue }
                let failed = block["is_error"] as? Bool == true
                step.status = !failed ? .done : denied.contains(Self.key(step)) ? .denied : .failed
                steps[id] = step; out.append(.step(step))
            }
        }
        for piece in try text.consume(event) {
            // Separate what the model says after a tool from what it said before.
            out.append(.text(afterStep && saidSomething ? "\n\n" + piece : piece)); afterStep = false; saidSomething = true
        }
        completed = text.completed
        return out
    }

    /// Answers a `can_use_tool` request with the user's decision.
    mutating func answer(_ request: [String: Any], approve: @MainActor @Sendable (ApprovalRequest) async -> ApprovalDecision) async -> [String: Any] {
        guard request["subtype"] as? String == "can_use_tool" else { return ["behavior": "deny", "message": "Unsupported request."] }
        let tool = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let step = Self.step(id: UUID().uuidString, tool: tool, input: input, directory: directory)
        let approval = ApprovalRequest(id: UUID().uuidString, action: Self.action(step), subject: Self.subject(step), directory: directory)
        switch await approve(approval) {
        case .allow, .allowForChat: return ["behavior": "allow", "updatedInput": input]
        case .deny:
            denied.insert(Self.key(step))
            return ["behavior": "deny", "message": "The user declined this in Boltbar."]
        }
    }

    static func key(_ step: AgentStep) -> String { step.kind.rawValue + "\u{1F}" + step.title }
    static func action(_ step: AgentStep) -> String { step.kind == .command ? "Run" : step.kind == .edit ? "Edit" : "Use" }
    static func subject(_ step: AgentStep) -> String {
        step.kind == .command ? String(step.title.dropFirst(2)) : step.title.split(separator: " ", maxSplits: 1).last.map(String.init) ?? step.title
    }
    static func step(id: String, tool: String, input: [String: Any], directory: String) -> AgentStep {
        let path = (input["file_path"] as? String ?? input["path"] as? String ?? input["notebook_path"] as? String).map { Agent.relative($0, to: directory) }
        switch tool {
        case "Bash": return AgentStep(id: id, kind: .command, title: "$ " + Agent.shorten(input["command"] as? String ?? ""))
        case "Read": return AgentStep(id: id, kind: .read, title: "Read " + (path ?? "a file"))
        case "Edit", "MultiEdit", "NotebookEdit": return AgentStep(id: id, kind: .edit, title: "Edit " + (path ?? "a file"))
        case "Write": return AgentStep(id: id, kind: .edit, title: "Write " + (path ?? "a file"))
        case "Grep": return AgentStep(id: id, kind: .search, title: "Search “\(Agent.shorten(input["pattern"] as? String ?? "", 40))”")
        case "Glob": return AgentStep(id: id, kind: .search, title: "Find " + Agent.shorten(input["pattern"] as? String ?? "", 40))
        case "LS": return AgentStep(id: id, kind: .read, title: "List " + (path ?? "folder"))
        case "TodoWrite": return AgentStep(id: id, kind: .tool, title: "Update the plan")
        case "Task", "Agent": return AgentStep(id: id, kind: .tool, title: "Agent: " + Agent.shorten(input["description"] as? String ?? "subtask", 50))
        default: return AgentStep(id: id, kind: .tool, title: tool)
        }
    }
}

// MARK: - Codex

/// Codex's app-server with a project folder, a sandbox and approval requests.
enum CodexAgent {
    static let arguments = ["app-server", "--listen", "stdio://", "--disable", "apps", "-c", "web_search=\"disabled\"", "-c", "mcp_servers={}"]
    static func policy(_ permission: AgentPermission) -> (sandbox: String, approval: String) {
        switch permission {
        case .look: return ("read-only", "never")
        case .ask: return ("workspace-write", "untrusted")
        // Codex has no "edits only" policy: it asks for everything and Boltbar accepts edits inside the project.
        case .edit: return ("workspace-write", "untrusted")
        case .full: return ("danger-full-access", "never")
        }
    }

    static func stream(_ request: ChatRequest, agent: AgentTurn, update: @escaping (StreamUpdate) async -> Void) async throws {
        let input = try CLIInput.blocks(request, codex: true)
        let child = try LineProcess(program: CLI.program(.openai), args: arguments, keepInputOpen: true, directory: agent.directory)
        defer { child.cancel() }
        try await withTaskCancellationHandler {
            try await child.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "boltbar", "title": "Boltbar", "version": "0.6.0"]]])
            var parser = CodexAgentStream(directory: agent.directory, permission: agent.permission)
            let (sandbox, approval) = policy(agent.permission)
            for try await line in child.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let id = event["id"], let method = event["method"] as? String {
                    try await child.send(["id": id, "result": await parser.answer(method, params: event["params"] as? [String: Any] ?? [:], approve: agent.approve)])
                    continue
                }
                if event["error"] != nil { throw AppError("Codex CLI rejected the request. Update Codex and check its login and selected model.") }
                switch event["id"] as? Int {
                case 1:
                    try await child.send(["method": "initialized", "params": [:]])
                    try await child.send(["id": 2, "method": "thread/start", "params": [
                        "model": request.model, "cwd": agent.directory, "ephemeral": true, "approvalPolicy": approval, "sandbox": sandbox,
                        "developerInstructions": Agent.instructions(agent.directory, for: .openai)]])
                case 2:
                    guard let result = event["result"] as? [String: Any], let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        throw AppError("Codex CLI returned an invalid thread. Update Codex and retry.")
                    }
                    try await child.send(["id": 3, "method": "turn/start", "params": ["threadId": id, "input": input, "effort": request.effort.rawValue]])
                default: break
                }
                for item in try parser.consume(event) { await update(item) }
                if parser.completed { return }
            }
            throw AppError("The Codex CLI connection ended before the response completed.")
        } onCancel: { child.cancel() }
    }
}

/// Turns Codex app-server notifications into text and steps, and approval requests into decisions.
struct CodexAgentStream {
    let directory: String
    let permission: AgentPermission
    private var text = CodexChatStream()
    private var steps: [String: AgentStep] = [:]
    private var changes: [String: [String]] = [:]
    private var afterStep = false
    private var saidSomething = false
    private(set) var completed = false
    init(directory: String, permission: AgentPermission = .ask) { self.directory = directory; self.permission = permission }

    mutating func consume(_ event: [String: Any]) throws -> [StreamUpdate] {
        var out: [StreamUpdate] = []
        let method = event["method"] as? String
        if method == "item/started" || method == "item/completed", let item = (event["params"] as? [String: Any])?["item"] as? [String: Any],
           let id = item["id"] as? String, var step = Self.step(item, directory: directory) {
            if let list = item["changes"] as? [[String: Any]] { changes[id] = list.compactMap { $0["path"] as? String } }
            if method == "item/completed" {
                let status = item["status"] as? String
                step.status = status == "declined" ? .denied : status == "failed" || (item["exitCode"] as? Int ?? 0) != 0 ? .failed : .done
                if let code = item["exitCode"] as? Int, code != 0 { step.detail = "exit \(code)" }
            }
            steps[id] = step; out.append(.step(step)); afterStep = true
        }
        for piece in try text.consume(event) {
            out.append(.text(afterStep && saidSomething ? "\n\n" + piece : piece)); afterStep = false; saidSomething = true
        }
        completed = text.completed
        return out
    }

    mutating func answer(_ method: String, params: [String: Any], approve: @MainActor @Sendable (ApprovalRequest) async -> ApprovalDecision) async -> [String: Any] {
        let request: ApprovalRequest
        switch method {
        case "item/commandExecution/requestApproval":
            request = ApprovalRequest(id: UUID().uuidString, action: "Run", subject: Self.command(params["command"] as? String ?? ""),
                                      directory: params["cwd"] as? String ?? directory)
        case "item/fileChange/requestApproval":
            if permission == .edit, params["grantRoot"] as? String == nil, let paths = (params["itemId"] as? String).flatMap({ changes[$0] }),
               !paths.isEmpty, paths.allSatisfy({ Agent.contains(directory, $0) }) {
                return ["decision": "accept"]
            }
            let subject = (params["itemId"] as? String).flatMap { steps[$0]?.title.split(separator: " ", maxSplits: 1).last.map(String.init) } ?? "files"
            request = ApprovalRequest(id: UUID().uuidString, action: "Edit", subject: subject, directory: directory)
        default:
            // Extra permissions, tool input and MCP prompts aren't offered in agent mode yet.
            return ["decision": "decline"]
        }
        switch await approve(request) {
        case .allow: return ["decision": "accept"]
        case .allowForChat: return ["decision": "acceptForSession"]
        case .deny: return ["decision": "decline"]
        }
    }

    /// Codex wraps commands as `/bin/zsh -lc "…"`; people want to read the command itself.
    static func command(_ raw: String) -> String {
        guard let range = raw.range(of: " -lc ") else { return raw }
        var inner = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if inner.count >= 2, let first = inner.first, first == inner.last, first == "\"" || first == "'" { inner = String(inner.dropFirst().dropLast()) }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
    static func step(_ item: [String: Any], directory: String) -> AgentStep? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "commandExecution":
            return AgentStep(id: id, kind: .command, title: "$ " + Agent.shorten(command(item["command"] as? String ?? "")))
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.map { Agent.relative($0, to: directory) }
            return AgentStep(id: id, kind: .edit, title: "Edit " + (paths.isEmpty ? "files" : paths.joined(separator: ", ")))
        case "mcpToolCall":
            return AgentStep(id: id, kind: .tool, title: item["tool"] as? String ?? "Tool")
        case "webSearch":
            return AgentStep(id: id, kind: .search, title: "Search the web")
        default: return nil
        }
    }
}
