import XCTest
@testable import BoltbarNative

/// ⌥Space brings back a chat that is still working and replaces an idle one;
/// ⌘N always replaces it.
final class SummonTests: XCTestCase {
    @MainActor private func model(_ provider: ScriptedProvider, store: ConversationStore? = nil) -> ChatModel {
        ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.summon.\(UUID())")!, historyStore: store, streamer: provider.streamer)
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var tries = 0
        while !condition() && tries < 500 { tries += 1; try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }
    @MainActor private func start(_ model: ChatModel, _ provider: ScriptedProvider) async {
        model.draft = "First"; model.send()
        await wait { provider.requests.count == 1 && model.messages.last?.text == "partial" }
    }

    @MainActor func testSummonWhileAReplyStreamsKeepsTheChatAndItsQueueStillGoesOut() async {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        model.draft = "Next"; model.send()
        model.draft = "unsent"; model.showHistory()
        model.barHidden()
        XCTAssertTrue(model.summon())
        XCTAssertTrue(model.streaming, "Reopening the bar must not stop the reply")
        XCTAssertEqual(model.messages.map(\.text), ["First", "partial"]); XCTAssertNil(model.messages[1].interrupted)
        XCTAssertEqual(model.queue.map(\.text), ["Next"]); XCTAssertFalse(model.queueHeld)
        XCTAssertEqual(model.draft, "unsent"); XCTAssertFalse(model.showingHistory, "The chat comes back, not the history browser")
        provider.finished = 1
        await wait { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].messages.map(\.text), ["First", "partial", "Next"])
    }

    @MainActor func testSummonWithAnIdleChatStartsANewOne() async {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        provider.finished = 1
        await wait { !model.streaming }
        model.barHidden()
        XCTAssertFalse(model.summon())
        XCTAssertTrue(model.messages.isEmpty)
    }

    @MainActor func testSummonKeepsAHeldQueueVisibleWithoutSendingIt() async {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        model.draft = "Next"; model.send()
        model.stop(); model.barHidden()
        XCTAssertTrue(model.summon())
        XCTAssertEqual(model.queue.map(\.text), ["Next"]); XCTAssertTrue(model.queueHeld)
        XCTAssertEqual(model.messages.last?.interrupted, true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 1, "Summoning never sends a held queue")
    }

    @MainActor func testAReplyThatFinishesWhileHiddenComesBackOnce() async {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        model.barHidden()
        provider.finished = 1
        await wait { !model.streaming }
        XCTAssertTrue(model.unreadReply)
        XCTAssertTrue(model.summon())
        XCTAssertEqual(model.messages.map(\.text), ["First", "partial"]); XCTAssertFalse(model.unreadReply)
        model.barHidden()
        XCTAssertFalse(model.summon(), "Once read, the next summon starts fresh")
        XCTAssertTrue(model.messages.isEmpty)
    }

    @MainActor func testNewChatStopsTheReplyAndSavesItsQueueHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boltbar-summon-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ConversationStore(directory: directory)
        let provider = ScriptedProvider(), model = model(provider, store: store)
        await start(model, provider)
        model.draft = "Later"; model.send()
        XCTAssertFalse(model.summon(newChat: true))
        XCTAssertFalse(model.streaming); XCTAssertTrue(model.messages.isEmpty); XCTAssertTrue(model.queue.isEmpty)
        provider.finished = 1
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 1, "A new chat never sends the old queue")
        store.flush()
        let record = try await store.load(try XCTUnwrap(store.summaries.first).id)
        XCTAssertEqual(record.messages.map(\.text), ["First", "partial"]); XCTAssertEqual(record.messages.last?.interrupted, true)
        XCTAssertEqual(record.queued?.map(\.text), ["Later"])
    }
}
