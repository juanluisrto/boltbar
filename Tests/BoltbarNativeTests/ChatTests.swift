import XCTest
@testable import BoltbarNative

final class ChatTests: XCTestCase {
    func testImagesAndDocumentsRemainInEveryRelevantRequest() throws {
        let image = try Attachment(name: "image.png", mime: "image/png", data: Data([1, 2, 3]))
        let document = try Attachment(name: "note.txt", mime: "text/plain", data: Data("ZAFIRO".utf8))
        let messages = [Message(role: .user, text: "Describe", attachments: [image, document]), Message(role: .assistant, text: "Description"), Message(role: .user, text: "What colors?")]
        for provider in [Provider.openai, .anthropic] {
            let request = ChatRequest(provider: provider, model: provider.defaults[0], effort: .low, transport: .api, messages: messages)
            let body = Providers.body(request)
            let items = body[provider == .openai ? "input" : "messages"] as! [[String: Any]]
            let content = items[0]["content"] as! [[String: Any]]
            XCTAssertEqual(content.count, 3)
            XCTAssertEqual(content[1]["type"] as? String, provider == .openai ? "input_image" : "image")
            XCTAssertTrue((content[2]["text"] as! String).contains("ZAFIRO"))
            XCTAssertEqual(items.count, 3)
        }
    }
    @MainActor func testSendMovesAttachmentsIntoHistoryAndResetsEditor() async throws {
        let completed = expectation(description: "request completed")
        let model = ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.memory")!, streamer: { _, delta in await delta("OK"); completed.fulfill() })
        let image = try Attachment(name: "image.png", mime: "image/png", data: Data([1]))
        model.attachments = [image]; model.draft = "Describe"; model.inputHeight = 160
        model.send()
        XCTAssertEqual(model.messages[0].attachments[0].id, image.id)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertEqual(model.inputHeight, 26)
        XCTAssertTrue(model.draft.isEmpty)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(model.messages.last?.text, "OK")
    }
    @MainActor func testResetRejectsLateFragmentsFromPreviousRequest() async throws {
        let started = expectation(description: "request started")
        var lateDelta: ((String) async -> Void)?
        let model = ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.memory")!, streamer: { _, delta in
            lateDelta = delta; started.fulfill(); try await Task.sleep(nanoseconds: 5_000_000_000)
        })
        model.draft = "Old chat"; model.send()
        await fulfillment(of: [started], timeout: 2)
        model.reset(); await lateDelta?("stale response")
        XCTAssertTrue(model.messages.isEmpty); XCTAssertFalse(model.streaming)
    }
    func testEditorStartsAtOneLineAndCapsGrowth() {
        XCTAssertEqual(GrowingEditor.height(for: 19), 26)
        XCTAssertEqual(GrowingEditor.height(for: 90), 90)
        XCTAssertEqual(GrowingEditor.height(for: 2000), 160)
        XCTAssertEqual(GrowingEditor.height(for: 19, manual: 80), 80)
    }
    func testUnsupportedModelsAreFiltered() {
        for id in ["gpt-4.1", "gpt-4o", "text-embedding-3-large", "gpt-6-audio", "gpt-6-realtime"] { XCTAssertFalse(Provider.openai.accepts(id)) }
        XCTAssertFalse(Provider.anthropic.accepts("claude-3-7-sonnet"))
        XCTAssertTrue(Provider.openai.accepts("gpt-6.1-sol"))
        XCTAssertTrue(Provider.anthropic.accepts("claude-sonnet-5-5"))
    }
    func testSSEFramesAndClaudePartialEvents() {
        var parser = EventFrames()
        XCTAssertNil(parser.consume("event: message"))
        XCTAssertNil(parser.consume("data: café 🦀"))
        XCTAssertNil(parser.consume("data: second line"))
        XCTAssertEqual(parser.consume(""), "café 🦀\nsecond line")
        XCTAssertNil(parser.consume(""))
        XCTAssertEqual(Providers.textDelta(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["text": "café"]]]), "café")
    }
    func testSSEPreservesUnicodeAndEmptyLineDelimiters() throws {
        var parser = EventFrames(); var received: [String] = []
        for byte in Data("data: café 🦀\r\n\r\ndata: done\n\n".utf8) {
            if let event = try parser.consume(byte: byte) { received.append(event) }
        }
        XCTAssertEqual(received, ["café 🦀", "done"])
    }
    func testMarkdownKeepsIncompleteFenceDuringStreaming() {
        let blocks = MarkdownText.blocks("**Hello**\n```swift\nlet value = 1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks[0].code); XCTAssertTrue(blocks[1].code)
        XCTAssertEqual(blocks[1].language, "swift"); XCTAssertEqual(blocks[1].text, "let value = 1")
    }
    func testAttachmentsRejectEmptyAndOversizeData() {
        XCTAssertThrowsError(try Attachment(name: "empty.txt", mime: "text/plain", data: Data()))
        XCTAssertThrowsError(try Attachment(name: "large.png", mime: "image/png", data: Data(count: Attachment.maxBytes + 1)))
        XCTAssertThrowsError(try Attachment(name: "opaque.bin", mime: "application/octet-stream", data: Data([0xFF, 0xFE])))
    }
    func testEachBorderAndCornerKeepsItsOppositeEdgesFixed() {
        let start = CGRect(x: 100, y: 200, width: 700, height: 300)
        let expected: [(ResizeRegion, CGRect)] = [
            (.left, CGRect(x: 140, y: 200, width: 660, height: 300)),
            (.right, CGRect(x: 100, y: 200, width: 740, height: 300)),
            (.top, CGRect(x: 100, y: 200, width: 700, height: 270)),
            (.bottom, CGRect(x: 100, y: 170, width: 700, height: 330)),
            (.topLeft, CGRect(x: 140, y: 200, width: 660, height: 270)),
            (.topRight, CGRect(x: 100, y: 200, width: 740, height: 270)),
            (.bottomLeft, CGRect(x: 140, y: 170, width: 660, height: 330)),
            (.bottomRight, CGRect(x: 100, y: 170, width: 740, height: 330)),
        ]
        for (region, frame) in expected {
            XCTAssertEqual(region.frame(from: start, delta: CGPoint(x: 40, y: -30),
                minimum: CGSize(width: 420, height: 112), maximum: CGSize(width: 1800, height: 1100)), frame, region.rawValue)
        }
        let clamped = ResizeRegion.bottomLeft.frame(from: start, delta: CGPoint(x: 1000, y: 1000),
            minimum: CGSize(width: 420, height: 112), maximum: CGSize(width: 1800, height: 1100))
        XCTAssertEqual(clamped.maxX, start.maxX); XCTAssertEqual(clamped.maxY, start.maxY)
        XCTAssertEqual(clamped.size, CGSize(width: 420, height: 112))
        XCTAssertEqual(GrowingEditor.height(for: 20, manual: 260), 260)
    }
}
