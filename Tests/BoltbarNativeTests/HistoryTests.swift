import XCTest
import AppKit
import SwiftUI
@testable import BoltbarNative

final class HistoryTests: XCTestCase {
    @MainActor func testHistoryFitsItsFirstActualViewportAndEveryResize() {
        _ = NSApplication.shared
        let scroll = HistoryScrollView(), table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.minWidth = 0; column.width = 668; table.addTableColumn(column)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        for width in [388.0, 980.0, 450.0] {
            scroll.setFrameSize(NSSize(width: width, height: 176))
            scroll.tile(); scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(column.width, scroll.contentView.bounds.width, accuracy: 0.5)
            XCTAssertEqual(table.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
            XCTAssertEqual(scroll.contentView.bounds.origin.x, 0)
        }
    }
    @MainActor func testDeleteRequiresTwoPressesAndCancelsOnNavigation() {
        _ = NSApplication.shared
        let items = (0..<2).map { ConversationSummary(id: UUID(), title: "Chat \($0)", createdAt: Date(), updatedAt: Date()) }
        var deleted: [UUID] = []
        let parent = HistoryTable(items: items, query: .constant(""), selectedID: .constant(nil),
                                  open: { _ in }, close: {}, delete: { deleted.append($0) })
        let coordinator = parent.makeCoordinator(), table = ConversationTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("conversation")))
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.reload(items)
        coordinator.deleteSelected()
        XCTAssertEqual(coordinator.pendingDeletionID, items[0].id); XCTAssertTrue(deleted.isEmpty)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertNil(coordinator.pendingDeletionID)
        coordinator.deleteSelected(); XCTAssertTrue(deleted.isEmpty)
        coordinator.deleteSelected(); XCTAssertEqual(deleted, [items[1].id])
        coordinator.deleteSelected(); XCTAssertTrue(coordinator.cancelDeletion())
        XCTAssertNil(coordinator.pendingDeletionID)
        var presses = 0
        table.deleteSelection = { presses += 1 }
        for repeating in [false, true, true] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "\u{7f}",
                                        charactersIgnoringModifiers: "\u{7f}", isARepeat: repeating, keyCode: 51)!
            table.keyDown(with: event)
        }
        XCTAssertEqual(presses, 1)
        let cell = coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0) as! ConversationCellView
        XCTAssertTrue(cell.trash.isHidden)
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        cell.mouseEntered(with: hover); XCTAssertFalse(cell.trash.isHidden)
        cell.trash.performClick(nil)
        XCTAssertEqual(deleted, [items[1].id, items[0].id])
        cell.mouseExited(with: hover); XCTAssertTrue(cell.trash.isHidden)
    }
    @MainActor func testDeletingActiveConversationPersistsAndDoesNotResurrect() async throws {
        let store = try store()
        let defaults = UserDefaults(suiteName: "com.boltbar.tests.delete.\(UUID())")!
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { _, delta in await delta(.text("Answer")) })
        model.draft = "Keep this"; model.send()
        while model.streaming { await Task.yield() }
        let kept = try XCTUnwrap(model.history.first?.id)
        model.reset(); model.draft = "Delete this"; model.send()
        while model.streaming { await Task.yield() }
        let removed = try XCTUnwrap(model.history.first?.id)
        _ = try await store.search("Delete")
        model.draft = "Unsent draft"; model.showHistory(); model.selectedHistoryID = removed
        await model.deleteConversation(removed)
        XCTAssertEqual(model.history.map(\.id), [kept]); XCTAssertEqual(model.selectedHistoryID, kept)
        XCTAssertTrue(model.messages.isEmpty); XCTAssertTrue(model.showingHistory)
        XCTAssertEqual(model.draft, "Unsent draft")
        model.finish(); model.showHistory(); model.finish()
        let reopened = try ConversationStore(directory: store.directory)
        XCTAssertEqual(reopened.summaries.map(\.id), [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(removed.uuidString + ".json").path))
        let matches = try await store.search("Delete")
        XCTAssertTrue(matches.isEmpty)
        await model.deleteConversation(kept)
        XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.selectedHistoryID)
    }
    func testFailedDeleteRestoresConversationAndIndex() async throws {
        let store = try store()
        let summary = ConversationSummary(id: UUID(), title: "Keep on failure", createdAt: Date(), updatedAt: Date())
        let record = Conversation(summary: summary, messages: [Message(role: .user, text: "Original")],
                                  provider: .openai, model: "gpt-6.1-sol", effort: .low, transport: .api)
        store.save(record) { _ in }; store.flush()
        let index = store.directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do { try await store.delete(summary.id); XCTFail("Expected index write to fail") } catch {}
        XCTAssertEqual(store.summaries.map(\.id), [summary.id])
        let restored = try await store.load(summary.id)
        XCTAssertEqual(restored.messages.first?.text, "Original")
    }
    @MainActor func testHistoryAppearanceOnMac() async throws {
        guard ProcessInfo.processInfo.environment["BOLTBAR_HISTORY_SNAPSHOTS"] == "1" else { return }
        _ = NSApplication.shared
        let model = ChatModel()
        model.history = ["Planning a weekend in the mountains", "A few ideas for Boltbar", "Quick question"].map {
            ConversationSummary(id: UUID(), title: $0, createdAt: Date(), updatedAt: Date())
        }
        let host = NSHostingView(rootView: HistoryPane(model: model, close: {}).padding(16).background(Color(white: 0.11)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua); window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            if let match = view as? T { return match }
            return view.subviews.compactMap { find($0, type) }.first
        }
        let browser = try XCTUnwrap(find(host, HistoryBrowserView.self))
        let table = try XCTUnwrap(browser.scroll.documentView as? ConversationTableView)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (name, width, confirming) in [("search", 560.0, false), ("delete", 420.0, true)] {
            window.setContentSize(NSSize(width: width, height: 260)); host.layoutSubtreeIfNeeded()
            if confirming { table.deleteSelection?() }
            try await Task.sleep(nanoseconds: 100_000_000)
            if let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ConversationCellView { cell.trash.isHidden = false }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: root.appendingPathComponent(".qa-local/history-\(name).png"))
        }
    }
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
    func testSearchFindsTitlesAndBothSidesOfChatWithoutAttachmentPayloads() async throws {
        let store = try store()
        let first = ConversationSummary(id: UUID(), title: "Plan del viaje", createdAt: Date(), updatedAt: Date(timeIntervalSince1970: 1))
        let second = ConversationSummary(id: UUID(), title: "Ideas para casa", createdAt: Date(), updatedAt: Date(timeIntervalSince1970: 2))
        let attachment = try Attachment(name: "hidden.txt", mime: "text/plain", data: Data("attachment-only".utf8))
        let messages = [Message(role: .user, text: "¿Dónde comer?", attachments: [attachment]),
                        Message(role: .assistant, text: "Prueba el café en Córdoba.")]
        for (summary, contents) in [(first, messages), (second, [Message(role: .user, text: "Muebles")])] {
            let record = Conversation(summary: summary, messages: contents, provider: .openai, model: "gpt-6.1-sol", effort: .low, transport: .api)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.save(record) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        }
        // Start with an empty cache, as after relaunching the app.
        let reopened = try ConversationStore(directory: store.directory)
        let title = try await reopened.search("VIAJE"), user = try await reopened.search("donde"), answer = try await reopened.search(" CAFE cordoba ")
        XCTAssertEqual(title, [first.id]); XCTAssertEqual(user, [first.id]); XCTAssertEqual(answer, [first.id])
        let absent = try await reopened.search("attachment-only"), empty = try await reopened.search("   ")
        XCTAssertTrue(absent.isEmpty); XCTAssertEqual(empty, [second.id, first.id])
        let updated = Conversation(summary: second, messages: [Message(role: .assistant, text: "Córdoba también")], provider: .openai, model: "gpt-6.1-sol", effort: .low, transport: .api)
        reopened.save(updated) { _ in }; reopened.flush()
        let refreshed = try await reopened.search("cordoba")
        XCTAssertEqual(refreshed, [second.id, first.id])
    }
    func testSearchSurvivesMissingAndDamagedChatsAndRetriesRestoredFiles() async throws {
        let store = try store()
        let healthy = ConversationSummary(id: UUID(), title: "Healthy chat", createdAt: Date(), updatedAt: Date(timeIntervalSince1970: 1))
        let missing = ConversationSummary(id: UUID(), title: "Missing chat", createdAt: Date(), updatedAt: Date(timeIntervalSince1970: 2))
        let damaged = ConversationSummary(id: UUID(), title: "Damaged chat", createdAt: Date(), updatedAt: Date(timeIntervalSince1970: 3))
        for summary in [healthy, missing, damaged] {
            let record = Conversation(summary: summary, messages: [Message(role: .assistant, text: "Zafiro")],
                                      provider: .openai, model: "gpt-6.1-sol", effort: .low, transport: .api)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.save(record) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        }
        let missingURL = store.directory.appendingPathComponent(missing.id.uuidString + ".json")
        let damagedURL = store.directory.appendingPathComponent(damaged.id.uuidString + ".json")
        let original = try Data(contentsOf: missingURL)
        try FileManager.default.removeItem(at: missingURL)
        try Data("invalid JSON".utf8).write(to: damagedURL)
        let reopened = try ConversationStore(directory: store.directory)
        let results = try await reopened.search("zafiro")
        XCTAssertEqual(results, [healthy.id])
        let titles = try await reopened.search("chat")
        XCTAssertEqual(titles, [damaged.id, missing.id, healthy.id])
        do { _ = try await reopened.load(damaged.id); XCTFail("Opening damaged chat must still report an error") }
        catch { /* Search recovery must not silently replace the stored conversation. */ }
        try original.write(to: missingURL)
        let restored = try await reopened.search("zafiro")
        XCTAssertEqual(restored, [missing.id, healthy.id])
    }
    @MainActor func testHistoryFilteringPreservesDraftAndNavigationState() async throws {
        let store = try store(), defaults = UserDefaults(suiteName: "com.boltbar.tests.history.search")!
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { _, update in await update(.text("Respuesta zafiro")) })
        model.draft = "Consulta inicial"; model.send()
        while model.streaming { await Task.yield() }
        model.draft = "Borrador intacto"; model.webSearch = true; model.showHistory(); model.historyQuery = "ZAFIRO"
        while model.searchingHistory { await Task.yield() }
        XCTAssertEqual(model.filteredHistory.count, 1)
        model.historyQuery = "nada coincide"
        while model.searchingHistory { await Task.yield() }
        XCTAssertTrue(model.filteredHistory.isEmpty)
        model.historyQuery = "zafiro"; model.closeHistory()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.historyQuery, "zafiro")
        XCTAssertEqual(model.draft, "Borrador intacto"); XCTAssertFalse(model.searchingHistory)
        model.showHistory()
        XCTAssertEqual(model.historyQuery, ""); XCTAssertEqual(model.filteredHistory.count, 1)
        model.historyQuery = "zafiro"
        while model.searchingHistory { await Task.yield() }
        let opened = await model.openConversation(try XCTUnwrap(model.history.first?.id))
        XCTAssertTrue(opened); XCTAssertTrue(model.webSearch)
        XCTAssertTrue(model.returnToHistory())
        while model.searchingHistory { await Task.yield() }
        XCTAssertEqual(model.historyQuery, "zafiro"); XCTAssertEqual(model.filteredHistory.count, 1)
        XCTAssertEqual(model.selectedHistoryID, model.history.first?.id)
        model.reset()
        XCTAssertEqual(model.historyQuery, ""); XCTAssertNil(model.selectedHistoryID); XCTAssertFalse(model.returnToHistory())
        model.finish()
    }
    @MainActor func testNewChatAndRestartKeepHistoryAndResumeTheSameConversation() async throws {
        let store = try store()
        let defaults = UserDefaults(suiteName: "com.boltbar.tests.history")!
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { _, delta in await delta(.text("First answer")) })
        let attachment = try Attachment(name: "note.txt", mime: "text/plain", data: Data("ZAFIRO".utf8))
        model.draft = "First chat"; model.attachments = [attachment]; model.send()
        while model.streaming { await Task.yield() }
        let id = try XCTUnwrap(model.history.first?.id)
        let firstDate = model.history.first?.updatedAt
        model.draft = "Unsent draft"; model.showHistory()
        XCTAssertTrue(model.showingHistory)
        model.closeHistory()
        XCTAssertEqual(model.draft, "Unsent draft")
        model.showHistory()
        model.reset()
        XCTAssertFalse(model.showingHistory)
        XCTAssertTrue(model.messages.isEmpty); XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.updatedAt, firstDate)
        model.finish()
        let restarted = ChatModel(defaults: defaults, historyStore: try ConversationStore(directory: store.directory), streamer: { request, delta in
            XCTAssertEqual(request.messages[0].attachments.first?.data, attachment.data)
            await delta(.text("Second answer"))
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
    @MainActor func testEachChatKeepsItsOwnUnsentDraft() async throws {
        let store = try store()
        let suite = "com.boltbar.tests.drafts.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { _, delta in await delta(.text("Answer")) })
        model.draft = "First chat"; model.send()
        while model.streaming { await Task.yield() }
        let first = try XCTUnwrap(model.history.first?.id)
        model.draft = "Half a thought\nand a second line"
        model.reset() // The shortcut on an idle chat, or ⌘N.
        XCTAssertEqual(model.draft, "", "A new chat starts empty")
        model.draft = "Second chat"; model.send()
        while model.streaming { await Task.yield() }
        let second = try XCTUnwrap(model.history.first?.id)
        model.draft = "Something else"

        var opened = await model.openConversation(first)
        XCTAssertTrue(opened); XCTAssertEqual(model.draft, "Half a thought\nand a second line")
        XCTAssertEqual(model.history.map(\.id), [second, first], "A draft doesn't reorder the list")
        opened = await model.openConversation(second)
        XCTAssertTrue(opened); XCTAssertEqual(model.draft, "Something else")
        model.send()
        while model.streaming { await Task.yield() }
        model.finish()

        let restarted = ChatModel(defaults: defaults, historyStore: try ConversationStore(directory: store.directory))
        opened = await restarted.openConversation(first)
        XCTAssertTrue(opened); XCTAssertEqual(restarted.draft, "Half a thought\nand a second line", "Drafts survive a restart")
        opened = await restarted.openConversation(second)
        XCTAssertTrue(opened); XCTAssertEqual(restarted.draft, "", "A draft that was sent is gone")
    }
    @MainActor func testLateStreamCannotOverwriteAnOpenedHistoryItem() async throws {
        let store = try store(), defaults = UserDefaults(suiteName: "com.boltbar.tests.history")!
        var lateDelta: ((StreamUpdate) async -> Void)?
        let started = expectation(description: "second stream")
        let model = ChatModel(defaults: defaults, historyStore: store, streamer: { request, delta in
            if request.messages.first?.text == "Saved" { await delta(.text("Saved reply")) }
            else { lateDelta = delta; started.fulfill(); try await Task.sleep(nanoseconds: 5_000_000_000) }
        })
        model.draft = "Saved"; model.send(); while model.streaming { await Task.yield() }
        let id = try XCTUnwrap(model.history.first?.id)
        model.reset(); model.draft = "Still streaming"; model.send()
        await fulfillment(of: [started], timeout: 2)
        let opened = await model.openConversation(id)
        XCTAssertTrue(opened); await lateDelta?(.text("Wrong conversation"))
        XCTAssertEqual(model.messages.last?.text, "Saved reply")
        XCTAssertEqual(model.history.count, 2); model.finish()
    }
}
