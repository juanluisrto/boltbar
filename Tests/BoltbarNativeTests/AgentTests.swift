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
        let look = ClaudeAgent.arguments(request(), agent: turn(.look))
        XCTAssertEqual(look[look.firstIndex(of: "--permission-prompts")! + 1], "none")
        XCTAssertFalse(look.contains("--permission-prompt-tool"))
        let ask = ClaudeAgent.arguments(request(), agent: turn(.ask))
        XCTAssertEqual(ask[ask.firstIndex(of: "--permission-mode")! + 1], "manual")
        XCTAssertEqual(ask[ask.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio")
        XCTAssertEqual(ask[ask.firstIndex(of: "--disallowedTools")! + 1], "WebSearch,WebFetch")
        XCTAssertTrue(ask.contains("--safe-mode"))
        XCTAssertEqual(CodexAgent.policy(.look).sandbox, "read-only")
        XCTAssertEqual(CodexAgent.policy(.look).approval, "never")
        XCTAssertEqual(CodexAgent.policy(.ask).sandbox, "workspace-write")
        XCTAssertEqual(CodexAgent.policy(.ask).approval, "untrusted")
        let edit = ClaudeAgent.arguments(request(), agent: turn(.edit))
        XCTAssertEqual(edit[edit.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
        XCTAssertEqual(edit[edit.firstIndex(of: "--permission-prompt-tool")! + 1], "stdio", "Edit still asks before commands")
        let full = ClaudeAgent.arguments(request(), agent: turn(.full))
        XCTAssertEqual(full[full.firstIndex(of: "--permission-mode")! + 1], "bypassPermissions")
        XCTAssertTrue(full.contains("--allow-dangerously-skip-permissions"))
        XCTAssertFalse(full.contains("--permission-prompt-tool"))
        XCTAssertEqual(CodexAgent.policy(.edit).sandbox, "workspace-write")
        XCTAssertEqual(CodexAgent.policy(.edit).approval, "untrusted", "Codex asks and Boltbar accepts edits in the project")
        XCTAssertEqual(CodexAgent.policy(.full).sandbox, "danger-full-access")
        XCTAssertEqual(CodexAgent.policy(.full).approval, "never")
    }

    func testCodexEditAcceptsChangesInsideTheProjectOnly() async throws {
        var stream = CodexAgentStream(directory: folder, permission: .edit)
        func change(_ id: String, _ path: String) throws {
            _ = try stream.consume(["method": "item/started", "params": ["item": ["id": id, "type": "fileChange", "status": "inProgress", "changes": [["path": path, "kind": ["type": "add"]]]]]])
        }
        try change("in", folder + "/Sources/a.swift")
        try change("out", "/etc/hosts")
        try change("climb", folder + "/../other/a.swift")
        try change("sibling", folder + "-copy/a.swift")
        var asked: [String] = []
        let inside = await stream.answer("item/fileChange/requestApproval", params: ["itemId": "in"]) { _ in XCTFail("Edits in the project go through"); return .deny }
        XCTAssertEqual(inside["decision"] as? String, "accept")
        for id in ["out", "climb", "sibling"] {
            let answer = await stream.answer("item/fileChange/requestApproval", params: ["itemId": id]) { approval in asked.append(id); return .deny }
            XCTAssertEqual(answer["decision"] as? String, "decline")
        }
        XCTAssertEqual(asked, ["out", "climb", "sibling"], "Changes outside the project still ask")
        let wider = await stream.answer("item/fileChange/requestApproval", params: ["itemId": "in", "grantRoot": "/"]) { _ in asked.append("root"); return .deny }
        XCTAssertEqual(wider["decision"] as? String, "decline")
        _ = await stream.answer("item/commandExecution/requestApproval", params: ["command": "make", "cwd": folder]) { _ in asked.append("make"); return .allow }
        XCTAssertEqual(asked.suffix(2), ["root", "make"], "Wider write access and commands still ask")

        var careful = CodexAgentStream(directory: folder, permission: .ask)
        _ = try careful.consume(["method": "item/started", "params": ["item": ["id": "in", "type": "fileChange", "changes": [["path": folder + "/a.swift"]]]]])
        let ask = await careful.answer("item/fileChange/requestApproval", params: ["itemId": "in"]) { _ in .allow }
        XCTAssertEqual(ask["decision"] as? String, "accept")
        XCTAssertTrue(Agent.contains(folder, "Sources/a.swift"), "Relative paths resolve against the project")
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
