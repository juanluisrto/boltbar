import XCTest
@testable import BoltbarNative

final class CLIChatTests: XCTestCase {
    func testSettingsReadEachCLIsOwnSignInStatus() async {
        // What `codex login status` and `claude auth status` print.
        XCTAssertEqual(CLI.status(.openai, output: "Logged in using ChatGPT\n"), .signedIn("with ChatGPT"))
        XCTAssertEqual(CLI.status(.openai, output: "Logged in using an API key - sk-proj-***abcd\n"), .signedIn("with an API key"), "The key itself is never shown")
        XCTAssertEqual(CLI.status(.openai, output: "Not logged in\n"), .signedOut)
        XCTAssertEqual(CLI.status(.anthropic, output: #"{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com"}"#), .signedIn("as me@example.com"))
        XCTAssertEqual(CLI.status(.anthropic, output: #"{"loggedIn": false}"#), .signedOut)
        // The CLI connection follows that status; the API key is used first when there is one.
        let signedIn = await Providers.catalog(.openai, transport: .cli, cli: .signedIn(nil))
        XCTAssertTrue(signedIn.ready)
        let signedOut = await Providers.catalog(.openai, transport: .cli, cli: .signedOut)
        XCTAssertFalse(signedOut.ready); XCTAssertTrue(signedOut.detail.hasPrefix("Run codex login"), signedOut.detail)
        let missing = await Providers.catalog(.anthropic, transport: .cli, cli: .missing)
        XCTAssertFalse(missing.ready); XCTAssertTrue(missing.detail.contains("Install the official Anthropic CLI"), missing.detail)
    }

    func testImagesAndHistoryAreSentInStructuredStdin() throws {
        let image = try Attachment(name: "sample.png", mime: "image/png", data: Data([1, 2, 3]))
        let request = ChatRequest(provider: .anthropic, model: "claude-haiku-5-5", effort: .low, transport: .cli,
                                  messages: [Message(role: .user, text: "Look", attachments: [image]),
                                             Message(role: .assistant, text: "A shape"), Message(role: .user, text: "What color?")])
        let invocation = try CLI.invocation(request)
        let json = try JSONSerialization.jsonObject(with: invocation.input) as! [String: Any]
        let message = json["message"] as! [String: Any], content = message["content"] as! [[String: Any]]
        XCTAssertEqual((content[2]["source"] as? [String: Any])?["data"] as? String, image.data.base64EncodedString())
        XCTAssertEqual(content.last?["text"] as? String, "user: What color?")
        XCTAssertFalse(invocation.arguments.joined().contains(image.data.base64EncodedString()))
        XCTAssertTrue(invocation.arguments.contains("--include-partial-messages"))
        XCTAssertTrue(invocation.arguments.contains("--safe-mode"))
        let codex = try CLIInput.blocks(request, codex: true)
        XCTAssertEqual(codex[2]["url"] as? String, "data:image/png;base64,AQID")
        XCTAssertEqual(codex[3]["text"] as? String, "assistant: A shape")
    }
    func testCodexStreamsBeforeCompletionWithoutDuplicatingSnapshot() throws {
        var parser = CodexChatStream()
        XCTAssertEqual(try parser.consume(["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "Hello "]]), ["Hello "])
        XCTAssertFalse(parser.completed)
        XCTAssertEqual(try parser.consume(["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "world"]]), ["world"])
        XCTAssertEqual(try parser.consume(["method": "item/completed", "params": ["item": ["id": "a", "type": "agentMessage", "text": "Hello world"]]]), [])
        _ = try parser.consume(["method": "turn/completed", "params": ["turn": ["status": "completed"]]])
        XCTAssertTrue(parser.completed)
    }
    func testFailedCodexTurnReportsErrorAfterPartialOutput() throws {
        var parser = CodexChatStream()
        _ = try parser.consume(["method": "item/agentMessage/delta", "params": ["itemId": "a", "delta": "Partial"]])
        XCTAssertThrowsError(try parser.consume(["method": "turn/completed", "params": ["turn": ["status": "failed"]]]))
        XCTAssertFalse(parser.completed)
    }
    func testClaudeDeltasAndResultAreNotDuplicated() throws {
        var parser = ClaudeChatStream()
        let event: [String: Any] = ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello"]]]
        XCTAssertEqual(try parser.consume(event), ["Hello"])
        XCTAssertFalse(parser.completed)
        XCTAssertEqual(try parser.consume(["type": "assistant", "message": ["content": [["type": "text", "text": "Hello"]]]]), [])
        XCTAssertEqual(try parser.consume(["type": "result", "subtype": "success", "is_error": false, "result": "Hello"]), [])
        XCTAssertTrue(parser.completed)
    }
    func testClaudeFinalOnlyFallbackAndFailure() throws {
        var parser = ClaudeChatStream()
        XCTAssertEqual(try parser.consume(["type": "result", "subtype": "success", "result": "Hello"]), ["Hello"])
        var failure = ClaudeChatStream()
        XCTAssertThrowsError(try failure.consume(["type": "result", "subtype": "error_during_execution", "is_error": true]))
    }
    func testProcessAllowsMultipleWritesWithoutClosingInput() async throws {
        let child = try LineProcess(program: "/bin/cat", args: [], keepInputOpen: true)
        defer { child.cancel() }
        var iterator = child.lines.makeAsyncIterator()
        try await child.send(["id": 1]); let first = try await iterator.next()
        try await child.send(["id": 2]); let second = try await iterator.next()
        XCTAssertTrue(first?.contains("1") == true); XCTAssertTrue(second?.contains("2") == true)
    }
    func testCancellationStopsWaitingCLIProcess() async throws {
        let child = try LineProcess(program: "/bin/sleep", args: ["20"])
        let task = Task { for try await _ in child.lines { } }
        task.cancel()
        _ = try? await task.value
        for _ in 0..<50 where child.process.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(child.process.isRunning)
        child.cancel()
    }
}
