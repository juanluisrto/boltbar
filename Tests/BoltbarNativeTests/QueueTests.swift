import XCTest
import AppKit
@testable import BoltbarNative

/// Each request streams "partial" (unless silent), then waits until the test
/// finishes it, so queue behaviour can be checked at every point of a turn.
private final class ScriptedProvider {
    var requests: [ChatRequest] = []
    var finished = 0
    var fails = false
    var silent = false
    var streamer: ChatModel.Streamer {
        { [self] request, update in
            let index = requests.count
            requests.append(request)
            if !silent { await update(.text("partial")) }
            while finished <= index { try await Task.sleep(nanoseconds: 2_000_000) }
            if fails { throw AppError("Provider failed") }
        }
    }
}

final class QueueTests: XCTestCase {
    @MainActor private func model(_ provider: ScriptedProvider, store: ConversationStore? = nil) -> ChatModel {
        ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.queue.\(UUID())")!, historyStore: store, streamer: provider.streamer)
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var tries = 0
        while !condition() && tries < 500 { tries += 1; try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }
    @MainActor private func start(_ model: ChatModel, _ provider: ScriptedProvider, _ text: String = "First") async {
        model.draft = text; model.send()
        await wait { provider.requests.count == 1 && (provider.silent || model.messages.last?.text == "partial") }
    }

    @MainActor func testTextDuringAReplyQueuesAndGoesOutTogetherWhenItFinishes() async {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        model.draft = "Also prices"; model.send()
        model.draft = "As a table"; model.send()
        XCTAssertEqual(model.queue.map(\.text), ["Also prices", "As a table"])
        XCTAssertTrue(model.draft.isEmpty); XCTAssertEqual(model.messages.count, 2)
        provider.finished = 1
        await wait { provider.requests.count == 2 }
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertEqual(provider.requests[1].messages.map(\.text), ["First", "partial", "Also prices", "As a table"])
        XCTAssertEqual(provider.requests[1].messages.map(\.role), [.user, .assistant, .user, .user])
    }

    @MainActor func testEmptyReturnInterruptsOnlyAfterTheDoublePressWindow() async {
        let provider = ScriptedProvider(), model = model(provider)
        var now: TimeInterval = 100; model.clock = { now }
        await start(model, provider)
        model.draft = "Next"; model.send()
        now += 0.2; model.send()
        XCTAssertTrue(model.streaming, "A quick second Return must not cut the reply")
        XCTAssertEqual(model.queue.count, 1)
        now += ChatModel.interruptDelay; model.send()
        await wait { provider.requests.count == 2 }
        XCTAssertEqual(model.messages[1].interrupted, true); XCTAssertEqual(model.messages[1].text, "partial")
        XCTAssertEqual(provider.requests[1].messages.map(\.text), ["First", "partial\n\n[Interrupted by the user]", "Next"])
        // The interrupted request ending late, or a second "Send now", sends nothing twice.
        provider.finished = 1; model.sendQueueNow()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(model.messages.filter { $0.text == "Next" }.count, 1)
    }

    @MainActor func testStopAndProviderErrorsHoldTheQueueUntilAnExplicitSend() async {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        model.draft = "Next"; model.send()
        model.stop()
        XCTAssertTrue(model.queueHeld); XCTAssertEqual(model.queue.map(\.text), ["Next"])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 1, "Stop never sends the queue by itself")
        model.send()
        await wait { provider.requests.count == 2 }
        XCTAssertFalse(model.queueHeld); XCTAssertTrue(model.queue.isEmpty)

        model.draft = "Third"; model.send()
        provider.fails = true; provider.finished = 2
        await wait { !model.streaming }
        XCTAssertNotNil(model.error); XCTAssertTrue(model.queueHeld); XCTAssertEqual(model.messages.last?.interrupted, true)
        XCTAssertEqual(provider.requests.count, 2, "A failed turn never sends the queue by itself")
        provider.fails = false
        model.retry()
        await wait { provider.requests.count == 3 }
        XCTAssertEqual(provider.requests[2].messages.last?.text, "Next")
        provider.finished = 3
        await wait { provider.requests.count == 4 }
        XCTAssertEqual(provider.requests[3].messages.last?.text, "Third")
    }

    @MainActor func testRepliesStoppedBeforeTheirFirstWordAreLeftOutOfTheNextRequest() async {
        let provider = ScriptedProvider(), model = model(provider)
        provider.silent = true
        await start(model, provider)
        model.stop()
        XCTAssertEqual(model.messages.last?.interrupted, true); XCTAssertEqual(model.messages.last?.text, "")
        model.draft = "Again"; model.send()
        await wait { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].messages.map(\.text), ["First", "Again"])
    }

    @MainActor func testEditingKeepsItsPlaceAndAttachmentsAndPausesTheQueue() async throws {
        let provider = ScriptedProvider(), model = model(provider)
        await start(model, provider)
        let image = try Attachment(name: "image.png", mime: "image/png", data: Data([1]))
        model.draft = "A"; model.attachments = [image]; model.send()
        model.draft = "B"; model.send()
        let a = model.queue[0].id, b = model.queue[1].id
        model.draft = "unsent"; model.editQueued(a)
        XCTAssertNil(model.editingQueuedID, "Editing must not replace text being written")
        model.draft = ""; model.editQueued(a)
        XCTAssertEqual(model.draft, "A"); XCTAssertEqual(model.attachments.map(\.id), [image.id]); XCTAssertTrue(model.queuePaused)
        model.draft = "A2"; model.attachments = []
        provider.finished = 1
        await wait { !model.streaming }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 1, "The queue waits for the edit")
        model.send()
        await wait { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].messages.suffix(2).map(\.text), ["A2", "B"])
        XCTAssertEqual(provider.requests[1].messages.suffix(2).map(\.id), [a, b])
        XCTAssertTrue(provider.requests[1].messages.suffix(2).allSatisfy { $0.attachments.isEmpty })

        model.draft = "C"; model.send()
        model.editQueued(model.queue[0].id)
        XCTAssertTrue(model.cancelQueuedEdit())
        XCTAssertTrue(model.draft.isEmpty); XCTAssertEqual(model.queue.map(\.text), ["C"]); XCTAssertFalse(model.queuePaused)
        provider.finished = 2
        await wait { provider.requests.count == 3 }
    }

    @MainActor func testPendingMessagesAreSavedWithTheChatAndReopenHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boltbar-queue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ConversationStore(directory: directory)
        let provider = ScriptedProvider(), model = model(provider, store: store)
        await start(model, provider)
        model.draft = "Later"; model.send()
        model.reset()
        XCTAssertTrue(model.queue.isEmpty)
        store.flush()
        let opened = await model.openConversation(try XCTUnwrap(store.summaries.first).id)
        XCTAssertTrue(opened)
        XCTAssertEqual(model.queue.map(\.text), ["Later"]); XCTAssertTrue(model.queueHeld)
        XCTAssertEqual(model.messages.last?.interrupted, true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 1, "Reopening a chat never sends its queue")
    }

    @MainActor func testHeldReturnSendsOnlyOnce() {
        _ = NSApplication.shared
        let text = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        var sends = 0
        text.onSend = { sends += 1 }
        for repeating in [false, true, true] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: 36)!
            text.keyDown(with: event)
        }
        XCTAssertEqual(sends, 1)
    }
}
