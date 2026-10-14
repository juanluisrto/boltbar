import XCTest
@testable import BoltbarNative

final class HistoryTests: XCTestCase {
    func store() throws -> ConversationStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/history-tests/\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try ConversationStore(directory: directory)
    }
    func testLatestStableModelPerApprovedFamily() {
        XCTAssertEqual(FeaturedModels.latest(["gpt-6-sol", "gpt-6.1-sol", "gpt-6.9-sol", "gpt-6.10-sol", "gpt-7-astra", "gpt-6-astra", "gpt-6-luna",
            "gpt-6.10-sol-2026-10-14", "gpt-7-astra-preview", "gpt-7-codex", "gpt-8-audio", "gpt-4o", "gpt-5-pro"]),
            ["gpt-7-astra", "gpt-6.10-sol", "gpt-6-luna"])
        XCTAssertEqual(FeaturedModels.latest(["gpt-6-luna", "gpt-4.1"]), ["gpt-6-luna"])
        XCTAssertEqual(Provider.openai.defaults, ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"])
    }
    func testDatesRespectCalendarDaysAndYears() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18, minute: 8))!
        XCTAssertEqual(ConversationDate.label(now, now: now, calendar: calendar), "18:08")
        XCTAssertEqual(ConversationDate.label(calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(ConversationDate.label(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13))!, now: now, calendar: calendar), "Sept 13")
        XCTAssertEqual(ConversationDate.label(calendar.date(from: DateComponents(year: 2025, month: 9, day: 13))!, now: now, calendar: calendar), "Sept 13, 2025")
    }
    func testStoreRoundTripPreservesMessagesAttachmentsAndPrivatePermissions() async throws {
        let store = try store()
        let attachment = try Attachment(name: "note.txt", mime: "text/plain", data: Data("ZAFIRO".utf8))
        let messages = [Message(role: .user, text: "Saved chat", attachments: [attachment]), Message(role: .assistant, text: "Saved answer")]
        let summary = ConversationSummary(id: UUID(), title: Conversation.title(for: messages), createdAt: Date(), updatedAt: Date())
        let record = Conversation(summary: summary, messages: messages, provider: .openai, model: "gpt-6.1-sol", effort: .high, transport: .api)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(record) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        let reopened = try ConversationStore(directory: store.directory)
        XCTAssertEqual(reopened.summaries.first?.title, "Saved chat")
        let loaded = try await reopened.load(summary.id)
        XCTAssertEqual(loaded.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(loaded.messages[0].attachments[0].id, attachment.id)
        XCTAssertEqual(loaded.messages[0].attachments[0].data, attachment.data)
        XCTAssertEqual(loaded.effort, .high); XCTAssertEqual(loaded.model, "gpt-6.1-sol")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent(summary.id.uuidString + ".json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    @MainActor func testNewChatAndRestartKeepHistoryAndResumeTheSameConversation() async throws {
        let store = try store()
        let defaults = UserDefaults(suiteName: "com.boltbar.tests.history")!
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { _, delta in await delta("First answer") })
        let attachment = try Attachment(name: "note.txt", mime: "text/plain", data: Data("ZAFIRO".utf8))
        model.draft = "First chat"; model.attachments = [attachment]; model.send()
        while model.streaming { await Task.yield() }
        let id = try XCTUnwrap(model.history.first?.id)
        let firstDate = model.history.first?.updatedAt
        model.reset()
        XCTAssertTrue(model.messages.isEmpty); XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.updatedAt, firstDate)
        model.finish()
        let restarted = ChatModel(defaults: defaults, historyStore: try ConversationStore(directory: store.directory), streamer: { request, delta in
            XCTAssertEqual(request.messages[0].attachments.first?.data, attachment.data)
            await delta("Second answer")
        })
        let opened = await restarted.openConversation(id)
        XCTAssertTrue(opened); XCTAssertEqual(restarted.messages.count, 2)
        XCTAssertEqual(restarted.messages.first?.attachments.first?.id, attachment.id)
        restarted.draft = "Follow up"; restarted.send()
        while restarted.streaming { await Task.yield() }
        restarted.finish()
        XCTAssertEqual(restarted.history.count, 1); XCTAssertEqual(restarted.history.first?.id, id)
        let loaded = try await store.load(id)
        XCTAssertEqual(loaded.messages.count, 4)
    }
    @MainActor func testLateStreamCannotOverwriteAnOpenedHistoryItem() async throws {
        let store = try store(), defaults = UserDefaults(suiteName: "com.boltbar.tests.history")!
        var lateDelta: ((String) async -> Void)?
        let started = expectation(description: "second stream")
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { request, delta in
            if request.messages.first?.text == "Saved" { await delta("Saved reply") }
            else { lateDelta = delta; started.fulfill(); try await Task.sleep(nanoseconds: 5_000_000_000) }
        })
        model.draft = "Saved"; model.send(); while model.streaming { await Task.yield() }
        let id = try XCTUnwrap(model.history.first?.id)
        model.reset(); model.draft = "Still streaming"; model.send()
        await fulfillment(of: [started], timeout: 2)
        let opened = await model.openConversation(id)
        XCTAssertTrue(opened); await lateDelta?("Wrong conversation")
        XCTAssertEqual(model.messages.last?.text, "Saved reply")
        XCTAssertEqual(model.history.count, 2); model.finish()
    }
}
