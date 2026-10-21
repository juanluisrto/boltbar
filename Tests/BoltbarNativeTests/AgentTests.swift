import XCTest
import AppKit
@testable import BoltbarNative

final class AgentTests: XCTestCase {
    private let folder = "/Users/me/Projects/app"
    private func turn(_ permission: AgentPermission, decision: ApprovalDecision = .allow) -> AgentTurn {
        AgentTurn(directory: folder, permission: permission) { _ in decision }
    }
    private func request(_ provider: Provider = .anthropic) -> ChatRequest {
        ChatRequest(provider: provider, model: provider.defaults[0], effort: .low, transport: .cli, messages: [Message(role: .user, text: "Fix the build")])
    }

    func testClaudeArgumentsFollowThePermission() {
        let look = ClaudeAgent.arguments(request(), agent: turn(.look), session: "s1")
        XCTAssertEqual(look[look.firstIndex(of: "--permission-mode")! + 1], "manual")
        XCTAssertEqual(look[look.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio", "Look's requests reach Boltbar, which refuses them")
        let ask = ClaudeAgent.arguments(request(), agent: turn(.ask), session: "s1")
        XCTAssertEqual(ask[ask.firstIndex(of: "--permission-mode")! + 1], "manual")
        XCTAssertEqual(ask[ask.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio")
        XCTAssertEqual(ask[ask.firstIndex(of: "--disallowedTools")! + 1], "WebSearch,WebFetch")
        XCTAssertTrue(ask.contains("--safe-mode"))
        XCTAssertEqual(CodexAgent.policy(.look).sandbox, "read-only")
        XCTAssertEqual(CodexAgent.policy(.look).approval, "never")
        XCTAssertEqual(CodexAgent.policy(.ask).sandbox, "workspace-write")
        XCTAssertEqual(CodexAgent.policy(.ask).approval, "untrusted")
        let edit = ClaudeAgent.arguments(request(), agent: turn(.edit), session: "s1")
        XCTAssertEqual(edit[edit.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
        XCTAssertEqual(edit[edit.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio", "Edit still asks before commands")
        let full = ClaudeAgent.arguments(request(), agent: turn(.full), session: "s1")
        XCTAssertEqual(full[full.firstIndex(of: "--permission-mode")! + 1], "bypassPermissions")
        for args in [look, ask, edit, full] {
            XCTAssertTrue(args.contains("--allow-dangerously-skip-permissions"), "Any turn can be switched to Full mid-turn")
            XCTAssertEqual(args[args.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio")
        }
        XCTAssertEqual(AgentPermission.allCases.map(ClaudeAgent.mode), ["default", "default", "acceptEdits", "bypassPermissions"])
        XCTAssertEqual(CodexAgent.policy(.edit).sandbox, "workspace-write")
        XCTAssertEqual(CodexAgent.policy(.edit).approval, "untrusted", "Codex asks and Boltbar accepts edits in the project")
        XCTAssertEqual(CodexAgent.policy(.full).sandbox, "danger-full-access")
        XCTAssertEqual(CodexAgent.policy(.full).approval, "never")
    }

    func testEachAgentGetsTheProjectRulesItWouldMiss() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boltbar-rules-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ text: String) throws { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func remove(_ name: String) throws { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        XCTAssertNil(Agent.projectRules(dir.path, for: .anthropic))
        XCTAssertEqual(Agent.instructions(dir.path, for: .anthropic), Agent.instructions(folder, for: .anthropic).replacingOccurrences(of: folder, with: dir.path))

        try write("AGENTS.md", "Run make test.")
        let fallback = try XCTUnwrap(Agent.projectRules(dir.path, for: .anthropic))
        XCTAssertTrue(fallback.contains("file=\"AGENTS.md\"") && fallback.contains("Run make test."), "Claude falls back to AGENTS.md")
        XCTAssertNil(Agent.projectRules(dir.path, for: .openai), "Codex reads AGENTS.md itself")

        try write("CLAUDE.md", "Use tabs."); try write(".claude/CLAUDE.md", "Prefer Swift."); try write("CLAUDE.local.md", "   ")
        let claude = try XCTUnwrap(Agent.projectRules(dir.path, for: .anthropic))
        XCTAssertTrue(claude.contains("Use tabs.") && claude.contains("Prefer Swift."))
        XCTAssertFalse(claude.contains("Run make test."), "CLAUDE.md wins over AGENTS.md")
        XCTAssertFalse(claude.contains("CLAUDE.local.md"), "Empty files are skipped")
        let args = ClaudeAgent.arguments(request(), agent: AgentTurn(directory: dir.path, permission: .look) { _ in .deny }, session: "s1")
        XCTAssertTrue(args[args.firstIndex(of: "--append-system-prompt")! + 1].contains("Use tabs."))

        try remove("AGENTS.md")
        let codex = try XCTUnwrap(Agent.projectRules(dir.path, for: .openai), "Codex gets CLAUDE.md when there's no AGENTS.md")
        XCTAssertTrue(codex.contains("Use tabs."))
        try write("AGENTS.override.md", "Override.")
        XCTAssertNil(Agent.projectRules(dir.path, for: .openai), "Codex reads its override itself too")

        try write("CLAUDE.md", String(repeating: "x", count: 50_000))
        let long = try XCTUnwrap(Agent.projectRules(dir.path, for: .anthropic))
        XCTAssertLessThan(long.count, 41_000); XCTAssertTrue(long.contains("the rest of this file was cut"))
    }

    @MainActor func testRequestsSayWhatTheyAreAndTheLightDecides() async throws {
        var stream = CodexAgentStream(directory: folder)
        func change(_ id: String, _ path: String) throws {
            _ = try stream.consume(["method": "item/started", "params": ["item": ["id": id, "type": "fileChange", "status": "inProgress", "changes": [["path": path, "kind": ["type": "add"]]]]]])
        }
        try change("in", folder + "/Sources/a.swift")
        try change("out", "/etc/hosts")
        try change("climb", folder + "/../other/a.swift")
        try change("sibling", folder + "-copy/a.swift")
        var seen: [ApprovalRequest] = []
        for (id, extra) in [("in", [:]), ("out", [:]), ("climb", [:]), ("sibling", [:]), ("in", ["grantRoot": "/"])] as [(String, [String: Any])] {
            let log = AskedLog()
            _ = await stream.answer("item/fileChange/requestApproval", params: extra.merging(["itemId": id]) { a, _ in a }) { request in log.requests.append(request); return .allow }
            seen += log.requests
        }
        XCTAssertEqual(seen.map(\.kind), Array(repeating: .edit, count: 5))
        XCTAssertEqual(seen.map(\.insideProject), [true, false, false, false, false], "Outside paths, climbing out and wider write access aren't inside")
        let command = AskedLog()
        _ = await stream.answer("item/commandExecution/requestApproval", params: ["command": "make", "cwd": folder]) { request in command.requests.append(request); return .allow }
        XCTAssertEqual(command.requests.first?.kind, .command)

        var claude = ClaudeAgentStream(directory: folder)
        let claudeLog = AskedLog()
        _ = await claude.answer(["subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": folder + "/a.txt", "content": "hi"]]) { claudeLog.requests.append($0); return .allow }
        _ = await claude.answer(["subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": "/tmp/a.txt", "content": "hi"]]) { claudeLog.requests.append($0); return .allow }
        XCTAssertEqual(claudeLog.requests.map(\.insideProject), [true, false])

        let edit = seen[0], outside = seen[1], run = command.requests[0]
        XCTAssertEqual(Agent.autoDecision(edit, permission: .look), .deny)
        XCTAssertNil(Agent.autoDecision(edit, permission: .ask))
        XCTAssertEqual(Agent.autoDecision(edit, permission: .edit), .allow, "Edit accepts changes inside the project")
        XCTAssertNil(Agent.autoDecision(outside, permission: .edit))
        XCTAssertNil(Agent.autoDecision(run, permission: .edit), "Edit still asks before commands")
        XCTAssertEqual(Agent.autoDecision(run, permission: .full), .allow)
        XCTAssertTrue(Agent.contains(folder, "Sources/a.swift"), "Relative paths resolve against the project")
    }

    @MainActor func testChangingThePermissionMidTurnAppliesAtOnce() async throws {
        var decisions: [ApprovalDecision] = [], changes: [AgentPermission] = []
        let changed = AskedLog()
        let model = model { request, update in
            request.agent?.control?.listen { permission in Task { @MainActor in changed.permissions.append(permission) } }
            let run = ApprovalRequest(id: "1", action: "Run", subject: "swift test", directory: request.agent!.directory, kind: .command)
            decisions.append(await request.agent!.approve(run))
            decisions.append(await request.agent!.approve(ApprovalRequest(id: "2", action: "Run", subject: "make", directory: request.agent!.directory, kind: .command)))
            await update(.text("Done."))
        }
        model.toggleAgentMode()
        let project = try XCTUnwrap(model.agentProject?.id)
        model.draft = "Test it"; model.send()
        await wait { model.pendingApproval != nil }
        model.setPermission(.full, for: project)
        await wait { !model.streaming }
        changes = changed.permissions
        XCTAssertEqual(decisions, [.allow, .allow], "Full answers the open request and the next one without asking")
        XCTAssertNil(model.pendingApproval)
        XCTAssertEqual(changes, [.full], "The running turn hears about the change")

        decisions = []
        model.setPermission(.look, for: project)
        model.draft = "Again"; model.send()
        await wait { !model.streaming }
        XCTAssertEqual(decisions, [.deny, .deny], "Look refuses by itself")
    }

    func testStepsSitBetweenTheWordsAroundThem() {
        let steps = [AgentStep(id: "a", kind: .read, title: "Read a", status: .done, at: 12),
                     AgentStep(id: "b", kind: .command, title: "$ make", status: .done, at: 12),
                     AgentStep(id: "c", kind: .edit, title: "Edit b", status: .done, at: 31)]
        let text = "Let me look.\n\nFound it, fixing.\n\nDone, it builds."
        let parts = MessageSegment.split(text, steps: steps).map { part -> String in
            switch part { case .text(let t): return "T:" + t; case .steps(let s): return "S:" + s.map(\.id).joined() }
        }
        XCTAssertEqual(parts, ["T:Let me look.", "S:ab", "T:Found it, fixing.", "S:c", "T:Done, it builds."])
        let old = [AgentStep(id: "x", kind: .read, title: "Read x", status: .done)]
        XCTAssertEqual(MessageSegment.split("Reply", steps: old).count, 2, "Older chats show their steps first")
        if case .steps = MessageSegment.split("Reply", steps: old).first {} else { XCTFail("Steps first") }
    }

    func testFileLinksResolveToFilesOnThisMac() throws {
        let base = "/Users/me/Projects/app"
        XCTAssertEqual(LocalLink.fileURL(URL(string: "pompeyo/README.md")!, base: base)?.path, base + "/pompeyo/README.md")
        XCTAssertEqual(LocalLink.fileURL(URL(string: "Sources/App.swift:42")!, base: base)?.path, base + "/Sources/App.swift")
        XCTAssertEqual(LocalLink.fileURL(URL(string: "/etc/hosts#L3")!, base: base)?.path, "/etc/hosts")
        XCTAssertEqual(LocalLink.fileURL(URL(string: "file:///tmp/a%20b.txt")!, base: base)?.path, "/tmp/a b.txt")
        XCTAssertEqual(LocalLink.fileURL(URL(string: "~/notes.md")!, base: base)?.path, NSHomeDirectory() + "/notes.md")
        XCTAssertEqual(LocalLink.fileURL(URL(string: "../shared/x.md")!, base: base)?.path, "/Users/me/Projects/shared/x.md")
        XCTAssertNil(LocalLink.fileURL(URL(string: "https://swift.org")!, base: base), "Web links go to the browser")
        XCTAssertNil(LocalLink.fileURL(URL(string: "mailto:a@b.c")!, base: base))
    }

    func testClaudeEventsBecomeStepsTextAndApprovals() async throws {
        var stream = ClaudeAgentStream(directory: folder)
        let use: [String: Any] = ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift build"]],
                                                                                ["type": "tool_use", "id": "t2", "name": "Edit", "input": ["file_path": folder + "/Sources/App.swift"]]]]]
        let started = try stream.consume(use)
        guard case .step(let build) = started[0], case .step(let edit) = started[1] else { return XCTFail("Missing steps") }
        XCTAssertEqual(build.title, "$ swift build"); XCTAssertEqual(build.kind, .command); XCTAssertEqual(build.status, .running)
        XCTAssertEqual(edit.title, "Edit Sources/App.swift")

        let denied = await stream.answer(["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "swift build"]]) { approval in
            XCTAssertEqual(approval.action, "Run"); XCTAssertEqual(approval.subject, "swift build"); return .deny
        }
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        let allowed = await stream.answer(["subtype": "can_use_tool", "tool_name": "Edit", "input": ["file_path": folder + "/Sources/App.swift"]]) { approval in
            XCTAssertEqual(approval.action, "Edit"); XCTAssertEqual(approval.subject, "Sources/App.swift"); return .allowForChat
        }
        XCTAssertEqual(allowed["behavior"] as? String, "allow")
        XCTAssertEqual((allowed["updatedInput"] as? [String: Any])?["file_path"] as? String, folder + "/Sources/App.swift")

        let results: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "denied"],
                                                                              ["type": "tool_result", "tool_use_id": "t2", "is_error": false, "content": "ok"]]]]
        let finished = try stream.consume(results)
        guard case .step(let deniedStep) = finished[0], case .step(let editedStep) = finished[1] else { return XCTFail("Missing updates") }
        XCTAssertEqual(deniedStep.status, .denied); XCTAssertEqual(editedStep.status, .done)

        let first = try stream.consume(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["text": "Fixed."]]])
        guard case .text(let opening) = first.first else { return XCTFail("Missing text") }
        XCTAssertEqual(opening, "Fixed.", "No blank paragraph when nothing was said before the tools")
        _ = try stream.consume(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t3", "name": "Read", "input": ["file_path": folder + "/README.md"]]]]])
        let after = try stream.consume(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["text": "Done."]]])
        guard case .text(let said) = after.first else { return XCTFail("Missing text") }
        XCTAssertEqual(said, "\n\nDone.", "Text after a tool call starts a new paragraph")
        _ = try stream.consume(["type": "result", "subtype": "success", "is_error": false])
        XCTAssertTrue(stream.completed)
    }

    func testCodexEventsBecomeStepsAndDecisions() async throws {
        var stream = CodexAgentStream(directory: folder)
        let item: [String: Any] = ["id": "c1", "type": "commandExecution", "command": "/bin/zsh -lc \"printf 'hi' > a.txt\"", "status": "inProgress"]
        guard case .step(let running) = try stream.consume(["method": "item/started", "params": ["item": item]]).first else { return XCTFail("Missing step") }
        XCTAssertEqual(running.title, "$ printf 'hi' > a.txt")
        var done = item; done["status"] = "declined"
        guard case .step(let declined) = try stream.consume(["method": "item/completed", "params": ["item": done]]).first else { return XCTFail("Missing update") }
        XCTAssertEqual(declined.status, .denied)
        var failing = item; failing["id"] = "c2"; failing["status"] = "completed"; failing["exitCode"] = 1
        guard case .step(let failed) = try stream.consume(["method": "item/completed", "params": ["item": failing]]).first else { return XCTFail("Missing update") }
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.detail, "exit 1")

        let accept = await stream.answer("item/commandExecution/requestApproval", params: ["command": "/bin/zsh -lc \"make\"", "cwd": folder]) { approval in
            XCTAssertEqual(approval.subject, "make"); return .allow
        }
        XCTAssertEqual(accept["decision"] as? String, "accept")
        let session = await stream.answer("item/fileChange/requestApproval", params: ["itemId": "x"]) { _ in .allowForChat }
        XCTAssertEqual(session["decision"] as? String, "acceptForSession")
        let other = await stream.answer("item/permissions/requestApproval", params: [:]) { _ in XCTFail("Never offered"); return .allow }
        XCTAssertEqual(other["decision"] as? String, "decline")
    }

    func testFullAccessLastsADayUnlessTurnedOffAndNamesStayDistinct() {
        var settings = AgentSettings()
        settings.projects = [AgentProject(path: "/a/api", permission: .full, fullSince: Date(timeIntervalSince1970: 0)),
                             AgentProject(path: "/b/api"), AgentProject(path: "/c/web", permission: .full, fullSince: Date())]
        XCTAssertEqual(settings.displayName(settings.projects[0]), "a/api")
        XCTAssertEqual(settings.displayName(settings.projects[2]), "web")
        var kept = settings; kept.fullAccessExpires = false
        XCTAssertFalse(kept.expireFullAccess()); XCTAssertEqual(kept.projects[0].permission, .full)
        XCTAssertTrue(settings.expireFullAccess())
        XCTAssertEqual(settings.projects[0].permission, .ask, "Expired full access starts later sessions at Ask")
        XCTAssertEqual(settings.projects[2].permission, .full, "Recent full access stays")
        XCTAssertNotNil(settings.fullAccessRemaining(settings.projects[2]))
    }

    @MainActor private func model(streamer: @escaping ChatModel.Streamer) -> ChatModel {
        let model = ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.agent.\(UUID())")!, streamer: streamer)
        model.agentSettings.projects = [AgentProject(path: NSTemporaryDirectory())]
        return model
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var tries = 0
        while !condition() && tries < 500 { tries += 1; try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }

    func testSessionsAreSavedAndContinued() throws {
        let fresh = ClaudeAgent.arguments(request(), agent: turn(.ask), session: "s1")
        XCTAssertEqual(fresh[fresh.firstIndex(of: "--session-id")! + 1], "s1")
        XCTAssertFalse(fresh.contains("--no-session-persistence"), "Sessions are kept so the terminal can resume them")
        var resumed = turn(.ask); resumed.resume = AgentResume(id: "s1", messages: [Message(role: .user, text: "And now?")])
        let again = ClaudeAgent.arguments(request(), agent: resumed, session: "s1")
        XCTAssertEqual(again[again.firstIndex(of: "--resume")! + 1], "s1"); XCTAssertFalse(again.contains("--session-id"))

        let only = try Agent.input(request(), agent: resumed, codex: false)
        XCTAssertEqual(only.compactMap { $0["text"] as? String }, ["And now?"], "A continued session reads only the new words, unlabelled")
        let whole = ChatRequest(provider: .anthropic, model: "m", effort: .low, transport: .cli,
                                messages: [Message(role: .user, text: "Hi"), Message(role: .assistant, text: "Hello"), Message(role: .user, text: "Fix it")])
        XCTAssertEqual(try Agent.input(whole, agent: turn(.ask), codex: true).compactMap { $0["text"] as? String }, ["user: Hi", "assistant: Hello", "user: Fix it"])
        XCTAssertEqual(try Agent.input(request(), agent: turn(.ask), codex: false).compactMap { $0["text"] as? String }, ["Fix the build"])

        let session = AgentSession(provider: .anthropic, directory: "/Users/me/Joe's app", id: "abc", seen: UUID())
        XCTAssertEqual(session.terminalCommand, "cd '/Users/me/Joe'\\''s app' && claude --resume abc")
        XCTAssertEqual(AgentSession(provider: .openai, directory: "/p", id: "t1", seen: UUID()).terminalCommand, "cd '/p' && codex resume t1")

        let summary = ConversationSummary(id: UUID(), title: "t", createdAt: Date(), updatedAt: Date())
        let record = Conversation(summary: summary, messages: [], provider: .anthropic, model: "m", effort: .low, transport: .cli, agentSession: session)
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(record)).agentSession, session)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]); legacy["agentSession"] = nil
        XCTAssertNil(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy)).agentSession, "Older chats still open")
    }

    @MainActor func testAChatContinuesItsSessionUntilItsHistoryChanges() async throws {
        var requests: [ChatRequest] = []
        let model = model { request, update in
            requests.append(request)
            await update(.agentSession(request.agent?.resume?.id ?? "session-\(requests.count)"))
            await update(.text("Done \(requests.count)."))
        }
        model.toggleAgentMode()
        model.draft = "One"; model.send(); await wait { !model.streaming }
        XCTAssertNil(requests.last?.agent?.resume, "The first turn starts a session")
        XCTAssertEqual(model.agentSession?.id, "session-1")
        XCTAssertEqual(model.agentSession?.seen, model.messages.last?.id)

        model.draft = "Two"; model.send(); await wait { !model.streaming }
        XCTAssertEqual(requests.last?.agent?.resume?.id, "session-1")
        XCTAssertEqual(requests.last?.agent?.resume?.messages.map(\.text), ["Two"], "Only what the session hasn't seen")

        model.agentMode = false
        model.draft = "Plain question"; model.send(); await wait { !model.streaming }
        model.agentMode = true
        model.draft = "Three"; model.send(); await wait { !model.streaming }
        XCTAssertEqual(requests.last?.agent?.resume?.messages.map(\.text), ["Plain question", "Done 3.", "Three"], "Turns outside agent mode are caught up")

        model.retry(); await wait { !model.streaming }
        XCTAssertNil(requests.last?.agent?.resume, "A retry rewrites history, so a new session starts")
        XCTAssertEqual(model.agentSession?.id, "session-5")

        let other = FileManager.default.temporaryDirectory.appendingPathComponent("boltbar-other-\(UUID())")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        model.addProject(path: other.path)
        model.draft = "Elsewhere"; model.send(); await wait { !model.streaming }
        XCTAssertNil(requests.last?.agent?.resume, "Another project starts its own session")
        XCTAssertEqual(model.agentSession?.directory, other.standardizedFileURL.path)

        model.copyTerminalCommand()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), model.agentSession?.terminalCommand)
        model.reset()
        XCTAssertNil(model.agentSession, "A new chat has no session")
    }

    @MainActor func testAStoppedReplyIsMentionedWhenTheSessionContinues() async {
        var requests: [ChatRequest] = []
        let model = model { request, update in
            requests.append(request)
            await update(.agentSession("s"))
            if requests.count == 1 { await update(.text("Halfway")); try? await Task.sleep(nanoseconds: 5_000_000_000) }
        }
        model.toggleAgentMode()
        model.draft = "Long job"; model.send()
        await wait { model.messages.last?.text == "Halfway" }
        model.stop()
        model.draft = "Never mind"; model.send(); await wait { requests.count == 2 }
        XCTAssertEqual(requests.last?.agent?.resume?.messages.map(\.text), ["[Your previous reply was interrupted by the user.]", "Never mind"])
    }

    @MainActor func testApprovalsWaitForTheUserAndAllowInThisChatSticks() async {
        var decisions: [ApprovalDecision] = []
        var seen: ChatRequest?
        let model = model { request, update in
            seen = request
            let ask = ApprovalRequest(id: "1", action: "Run", subject: "swift build", directory: request.agent!.directory)
            await update(.step(AgentStep(id: "s1", kind: .command, title: "$ swift build")))
            decisions.append(await request.agent!.approve(ask))
            decisions.append(await request.agent!.approve(ask))
            await update(.step(AgentStep(id: "s1", kind: .command, title: "$ swift build", status: .done)))
            await update(.text("Built."))
        }
        model.webSearch = true; model.toggleAgentMode()
        XCTAssertTrue(model.agentMode); XCTAssertTrue(model.selectingAgent, "Turning agent mode on selects its chip")
        model.draft = "Build it"; model.send()
        await wait { model.pendingApproval != nil }
        XCTAssertEqual(model.pendingApproval?.subject, "swift build")
        XCTAssertEqual(seen?.webSearch, false, "Web search is off in agent mode")
        XCTAssertEqual(seen?.agent?.permission, .ask)
        model.resolveApproval(.allowForChat)
        await wait { !model.streaming }
        XCTAssertEqual(decisions, [.allowForChat, .allow], "The same request is allowed again in this chat")
        XCTAssertEqual(model.messages.last?.steps?.map(\.status), [.done], "A step is updated in place")
        XCTAssertEqual(model.messages.last?.text, "Built.")
    }

    @MainActor func testTabWalksFromTheModelChipToTheAgentChipAndBack() {
        let model = ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.agent.tab.\(UUID())")!)
        model.agentMode = false
        XCTAssertTrue(model.switchChipSelection(forward: true))
        XCTAssertTrue(model.selectingModel); XCTAssertFalse(model.selectingAgent)
        XCTAssertTrue(model.switchChipSelection(forward: true))
        XCTAssertTrue(model.selectingAgent, "The agent chip is reachable with agent mode off")
        XCTAssertFalse(model.selectingModel); XCTAssertFalse(model.agentMode, "Moving never turns agent mode on")
        XCTAssertTrue(model.switchChipSelection(forward: true))
        XCTAssertTrue(model.selectingAgent, "Tab stays on the agent chip")
        model.toggleAgentMode(keepingSelection: true)
        XCTAssertTrue(model.agentMode); XCTAssertTrue(model.selectingAgent)
        model.toggleAgentMode(keepingSelection: true)
        XCTAssertFalse(model.agentMode); XCTAssertTrue(model.selectingAgent, "↵ again turns it off and stays on the chip")
        XCTAssertTrue(model.switchChipSelection(forward: false))
        XCTAssertTrue(model.selectingModel); XCTAssertFalse(model.selectingAgent)
        XCTAssertTrue(model.switchChipSelection(forward: false))
        XCTAssertTrue(model.selectingModel, "⇧Tab stays on the model chip")
        model.showingAgentPicker = true; model.selectingModel = false
        XCTAssertTrue(model.switchChipSelection(forward: true))
        XCTAssertTrue(model.selectingAgent); XCTAssertFalse(model.showingAgentPicker, "Tab from an open popover keeps the agent chip and closes it")
    }

    @MainActor func testStoppingAnswersAnOpenRequestWithNo() async {
        var decision: ApprovalDecision?
        let model = model { request, _ in
            decision = await request.agent!.approve(ApprovalRequest(id: "1", action: "Run", subject: "rm -rf build", directory: "/"))
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        model.agentMode = true
        model.draft = "Clean"; model.send()
        await wait { model.pendingApproval != nil }
        model.stop()
        await wait { decision != nil }
        XCTAssertEqual(decision, .deny); XCTAssertNil(model.pendingApproval)
    }

    @MainActor func testCommandsRunLocallyAndFoldersBecomeProjects() async throws {
        var sent = 0
        let model = model { _, _ in sent += 1 }
        model.draft = "/help"; model.send()
        XCTAssertTrue(model.showingHelp); XCTAssertTrue(model.draft.isEmpty)
        model.draft = "/agent"; model.send()
        XCTAssertTrue(model.agentMode)
        XCTAssertEqual(sent, 0, "Commands are never sent to a model")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boltbar-project-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = NSPasteboard(name: NSPasteboard.Name("boltbar-test-\(UUID())"))
        board.clearContents(); board.writeObjects([dir as NSURL])
        model.agentMode = false
        XCTAssertTrue(model.receive(board))
        XCTAssertTrue(model.agentMode, "Dropping a folder turns agent mode on")
        XCTAssertEqual(model.agentProject?.name, dir.lastPathComponent)
        XCTAssertTrue(model.attachments.isEmpty)

        let count = model.agentSettings.projects.count
        model.requestProjectRemoval()
        XCTAssertEqual(model.agentSettings.projects.count, count, "Removing asks twice")
        model.requestProjectRemoval()
        XCTAssertEqual(model.agentSettings.projects.count, count - 1)
        model.requestProjectRemoval(); model.requestProjectRemoval()
        XCTAssertEqual(model.agentSettings.projects.count, 1, "The last project stays")

        model.stepPermission(-1)
        XCTAssertEqual(model.agentProject?.permission, .look)
        model.stepPermission(-1)
        XCTAssertEqual(model.agentProject?.permission, .look)
        model.stepPermission(1); model.stepPermission(1)
        XCTAssertEqual(model.agentProject?.permission, .edit)
        let id = try XCTUnwrap(model.agentProject?.id)
        model.stepPermission(1)
        XCTAssertEqual(model.agentProject?.permission, .edit, "Full takes a second press")
        XCTAssertEqual(model.pendingFullAccess, id)
        model.stepPermission(-1)
        XCTAssertEqual(model.agentProject?.permission, .edit, "← while Full waits stays on Edit")
        XCTAssertNil(model.pendingFullAccess)
        model.stepPermission(1); model.stepPermission(1)
        XCTAssertEqual(model.agentProject?.permission, .full)
        let since = try XCTUnwrap(model.agentProject?.fullSince)
        model.stepPermission(1)
        XCTAssertEqual(model.agentProject?.fullSince, since, "Pressing → on Full doesn't restart its day")
        model.stepPermission(-1)
        XCTAssertEqual(model.agentProject?.permission, .edit); XCTAssertNil(model.agentProject?.fullSince)
        model.choosePermission(.full, for: id)
        XCTAssertEqual(model.agentProject?.permission, .edit, "A click on Full asks for a second one too")
        model.endModelSelection()
        XCTAssertNil(model.pendingFullAccess, "Leaving the chip forgets the first press")
        model.setPermission(.full, for: id)
        XCTAssertEqual(model.agentProject?.permission, .full, "Settings sets Full directly")
    }
}

/// What the approval handler was asked, kept on the main actor where the handler runs.
@MainActor private final class AskedLog {
    var asked: [String] = []
    var requests: [ApprovalRequest] = []
    var permissions: [AgentPermission] = []
}
