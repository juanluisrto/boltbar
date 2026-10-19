import XCTest
@testable import BoltbarNative

final class WebSearchTests: XCTestCase {
    func testClaudeSearchToolsAreOptInForAPIAndCLI() throws {
        var request = ChatRequest(provider: .anthropic, model: "claude-haiku-5-5", effort: .low, transport: .cli,
            messages: [Message(role: .user, text: "Search Swift downloads")])
        XCTAssertNil(Providers.body(request)["tools"])
        XCTAssertFalse(try CLI.invocation(request).arguments.contains("WebSearch,WebFetch"))
        request.webSearch = true
        let tools = Providers.body(request)["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["name"] as? String, "web_search")
        let args = try CLI.invocation(request).arguments
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "WebSearch,WebFetch")
        XCTAssertEqual(args[args.firstIndex(of: "--allowedTools")! + 1], "WebSearch,WebFetch")
        XCTAssertTrue(args.contains(CLIInput.webInstructions))
    }
    func testClaudeStreamingCitationsAndSearchErrors() throws {
        var stream = AnthropicTextStream()
        let start = try stream.consume(["type": "content_block_start", "content_block": ["type": "server_tool_use", "name": "web_search"]])
        guard case .activity("Searching the web…") = start.first else { return XCTFail("Missing activity") }
        _ = try stream.consume(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Swift"]])
        XCTAssertTrue(try stream.consume(["type": "content_block_delta", "delta": ["type": "citations_delta", "citation": ["type": "web_search_result_location", "url": "https://swift.org/download/"]]]).isEmpty)
        let result = try stream.consume(["type": "content_block_stop"])
        guard case .text(" [1](<https://swift.org/download/>)") = result.first else { return XCTFail("Missing citation") }
        XCTAssertThrowsError(try stream.consume(["type": "content_block_start", "content_block": ["type": "web_search_tool_result", "content": ["type": "web_search_tool_result_error", "error_code": "unavailable"]]]))
    }
    func testClaudeCitationsFollowTheirClaimWithoutTouchingTheNextWord() throws {
        func render(_ blocks: [(text: String, urls: [String])], citationsFirst: Bool = false) throws -> String {
            var stream = AnthropicTextStream(), output = ""
            func feed(_ event: [String: Any]) throws { for case .text(let value) in try stream.consume(event) { output += value } }
            for block in blocks {
                let citations = block.urls.map { ["type": "content_block_delta", "delta": ["type": "citations_delta",
                    "citation": ["type": "web_search_result_location", "url": $0]]] as [String: Any] }
                try feed(["type": "content_block_start", "content_block": ["type": "text", "text": ""]])
                if citationsFirst { try citations.forEach(feed) }
                for piece in block.text.split(separator: "|", omittingEmptySubsequences: false) {
                    try feed(["type": "content_block_delta", "delta": ["type": "text_delta", "text": String(piece)]])
                }
                if !citationsFirst { try citations.forEach(feed) }
                try feed(["type": "content_block_stop"])
            }
            return output
        }
        let a = "https://a.example/", b = "https://b.example/"
        XCTAssertEqual(try render([("Released in March", [a]), ("If you need", [])]),
                       "Released in March [1](<\(a)>) If you need")
        XCTAssertEqual(try render([("Released in March", [a]), (". Max", [])], citationsFirst: true),
                       "Released in March [1](<\(a)>). Max")
        XCTAssertEqual(try render([("- First |item\n", [a, b, a]), ("- Second", [b])]),
                       "- First item [1](<\(a)>) [2](<\(b)>)\n- Second [2](<\(b)>)")
        XCTAssertEqual(try render([("Plain text", [])]), "Plain text")
    }
    func testOpenAICitationMarkersAreSeparatedFromTheFollowingWord() {
        let marker = "\u{E200}cite\u{E202}turn0search0\u{E201}", text = "Done.\(marker)If you"
        let start = "Done.".unicodeScalars.count, end = start + marker.unicodeScalars.count
        let citation: [String: Any] = ["type": "url_citation", "start_index": start, "end_index": end, "url": "https://swift.org/"]
        XCTAssertEqual(WebCitations.markdown(text, annotations: [citation]), "Done. [1](<https://swift.org/>) If you")
        var claim = citation; claim["start_index"] = 0; claim["end_index"] = 4
        XCTAssertEqual(WebCitations.markdown("Done. Next", annotations: [claim]), "Done [1](<https://swift.org/>). Next")
    }
    func testRenderedCitationsStaySeparatedEvenInOldSavedText() {
        func plain(_ source: String) -> String { String(InlineMarkdown.render(source, accent: .blue).characters) }
        let a = "https://a.example/x", b = "https://b.example/"
        XCTAssertEqual(plain("March[1](<\(a)>)If you"), "March \u{2009}1\u{2009} If you")
        XCTAssertEqual(plain("March [1](<\(a)>)[2](<\(b)>)."), "March \u{2009}1\u{2009} \u{2009}2\u{2009}.")
        XCTAssertEqual(plain("Read [the guide](\(b)) now"), "Read the guide now", "Descriptive links keep their words")
        XCTAssertEqual(plain("In [2024](\(b)) and [1](file:///etc/passwd)"), "In 2024 and 1", "Only short web numbers are citations")
        let sources = InlineMarkdown.sources("A [2](<\(b)>) B [1](<https://www.a.example/x>) [1](<\(b)>) [3](file:///etc/passwd)")
        XCTAssertEqual(sources.map(\.number), [1, 2])
        XCTAssertEqual(sources.map(\.domain), ["a.example", "b.example"])
    }
    func testSearchIsOptInAndLetsTheModelDecideWhetherToUseIt() {
        var request = ChatRequest(provider: .openai, model: "gpt-6.1-sol", effort: .low, transport: .api,
            messages: [Message(role: .user, text: "Find Swift downloads")])
        let plain = Providers.body(request)
        XCTAssertNil(plain["tools"]); XCTAssertNil(plain["tool_choice"])
        request.webSearch = true
        let search = Providers.body(request)
        XCTAssertNil(search["tool_choice"], "Use the API default automatic tool selection, never force a search")
        XCTAssertEqual((search["tools"] as? [[String: String]])?.map { $0["type"] }, ["web_search"])
        XCTAssertEqual(search["model"] as? String, "gpt-6.1-sol")
    }
    func testSearchActivityOnlyStartsAfterARealSearchEvent() {
        var stream = OpenAITextStream()
        XCTAssertTrue(stream.consume(["type": "response.created"]).isEmpty)
        let greeting = stream.consume(["type": "response.output_text.delta", "delta": "Hello!"])
        guard case .text("Hello!") = greeting.first else { return XCTFail("A normal reply must not announce a search") }
        let searching = stream.consume(["type": "response.web_search_call.in_progress"])
        guard case .activity("Searching the web…") = searching.first else { return XCTFail("Missing search activity") }
        let writing = stream.consume(["type": "response.web_search_call.completed"])
        guard case .activity("Writing answer…") = writing.first else { return XCTFail("Missing completion activity") }
    }
    func testCitationLinksPreserveUnicodeClaimsAndGroupSharedMarkers() {
        let text = "🦀 Café. citeturn0search0"
        let start = "🦀 Café. ".unicodeScalars.count, end = text.unicodeScalars.count
        let citation: [String: Any] = ["type": "url_citation", "start_index": start, "end_index": end, "url": "https://swift.org/download/", "title": "Swift"]
        var second = citation; second["url"] = "https://swift.org/documentation/"
        let rendered = WebCitations.markdown(text, annotations: [citation, second, citation])
        XCTAssertEqual(rendered, "🦀 Café. [1](<https://swift.org/download/>) [2](<https://swift.org/documentation/>)")
        var claim = citation; claim["start_index"] = 0; claim["end_index"] = 7
        XCTAssertEqual(WebCitations.markdown("🦀 Café.", annotations: [claim]), "🦀 Café. [1](<https://swift.org/download/>)")
        var unsafe = citation; unsafe["url"] = "file:///etc/passwd"
        XCTAssertEqual(WebCitations.markdown(text, annotations: [unsafe]), text)
    }
    func testStreamingAnnotationsAndCompletionProduceCopyableLinks() {
        var stream = OpenAITextStream()
        let raw = "Swift citeturn0search0"
        let annotation: [String: Any] = ["type": "url_citation", "start_index": 6,
            "end_index": raw.unicodeScalars.count, "url": "https://swift.org/", "title": "Swift"]
        _ = stream.consume(["type": "response.output_text.delta", "delta": raw, "output_index": 1, "content_index": 0])
        let updates = stream.consume(["type": "response.output_text.annotation.added", "output_index": 1,
            "content_index": 0, "annotation_index": 0, "annotation": annotation])
        guard case .replaceText(let rendered) = updates.first else { return XCTFail("Missing annotated text") }
        XCTAssertEqual(rendered, "Swift [1](<https://swift.org/>)")
        let part: [String: Any] = ["type": "output_text", "text": raw, "annotations": [annotation]]
        let output: [[String: Any]] = [["type": "web_search_call"], ["type": "message", "content": [part]]]
        let done = stream.consume(["type": "response.completed", "response": ["output": output]])
        guard case .replaceText(let final) = done.first else { return XCTFail("Missing final text") }
        XCTAssertEqual(final, rendered)
    }
    func testSearchRejectsCLIWithoutStartingAnyAgent() async {
        let request = ChatRequest(provider: .openai, model: "gpt-6.1-sol", effort: .low, transport: .cli,
            messages: [Message(role: .user, text: "Search")], webSearch: true)
        do { try await Providers.stream(request) { _ in }; XCTFail("CLI search must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
    }
    @MainActor func testSearchChoicePersistsButLateUpdatesDoNotLeakIntoNewChats() async {
        let started = expectation(description: "started")
        var late: ((StreamUpdate) async -> Void)?
        let suite = "com.boltbar.tests.web.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ChatModel(defaults: defaults, streamer: { request, update in
            XCTAssertTrue(request.webSearch)
            late = update; await update(.activity("Searching the web…")); started.fulfill()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        })
        model.preferences.provider = .openai; model.preferences.transports["openai"] = .api
        model.webSearch = true; model.draft = "Search"; model.send()
        XCTAssertNil(model.messages.last?.activity, "Enabling web access is not evidence that a search has started")
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.messages.last?.activity, "Searching the web…")
        model.reset(); await late?(.replaceText("late source")); await late?(.activity("late activity"))
        XCTAssertTrue(model.messages.isEmpty); XCTAssertTrue(model.webSearch)
        model.preferences.provider = .anthropic
        XCTAssertTrue(model.webSearch); XCTAssertTrue(model.webSearchActive)
        model.preferences.provider = .openai
        XCTAssertTrue(model.webSearchActive)
        let restarted = ChatModel(defaults: defaults)
        XCTAssertTrue(restarted.webSearchActive)
        restarted.webSearch = false; restarted.reset()
        XCTAssertFalse(restarted.webSearch)
        XCTAssertFalse(ChatModel(defaults: defaults).webSearch)
    }
    func testOldSavedMessagesWithoutActivityStillDecode() throws {
        let old = "{\"id\":\"813132B1-B4EC-48E9-B271-F576A6820156\",\"role\":\"assistant\",\"text\":\"Saved reply\",\"attachments\":[],\"pending\":false}"
        let message = try JSONDecoder().decode(Message.self, from: Data(old.utf8))
        XCTAssertEqual(message.text, "Saved reply"); XCTAssertNil(message.activity)
    }
}
