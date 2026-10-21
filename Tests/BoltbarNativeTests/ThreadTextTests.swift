import AppKit
import XCTest
@testable import BoltbarNative

@MainActor final class ThreadTextTests: XCTestCase {
    private let theme = ThemeName.graphite.palette
    private func makeModel() -> ChatModel { ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.thread.\(UUID())")!) }

    func testAReplyReadsInOrderWithItsParts() throws {
        let text = "Let me look.\n\nUse `make` and see [App.swift](Sources/App.swift), **done**.\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let message = Message(role: .assistant, text: text, author: "Anthropic",
                              steps: [AgentStep(id: "s", kind: .command, title: "$ swift build", status: .done, at: 12)])
        let piece = ThreadBuilder.piece(message, first: true, style: ThreadStyle(theme: theme))
        let string = piece.text.string as NSString
        XCTAssertTrue((string as String).hasPrefix("ANTHROPIC\n"))
        XCTAssertEqual(string.substring(with: piece.label), "ANTHROPIC")
        let look = string.range(of: "Let me look."), step = string.range(of: "$ swift build"), use = string.range(of: "Use make")
        XCTAssertTrue(look.upperBound <= step.location && step.upperBound <= use.location, "Steps sit between the words around them")
        XCTAssertEqual(piece.codeBlocks.map(\.source), ["let x = 1"])
        XCTAssertNotNil(piece.text.attribute(.boltbarCode, at: piece.codeBlocks[0].range.location, effectiveRange: nil))
        let link = string.range(of: "App.swift")
        XCTAssertEqual((piece.text.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.relativeString, "Sources/App.swift")
        let bold = try XCTUnwrap(piece.text.attribute(.font, at: string.range(of: "done").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue((string as String).contains("A\nB\n1\n2\n"), "Table cells are text you can select")

        let stopped = Message(role: .assistant, text: "", pending: false, author: "OpenAI", interrupted: true)
        XCTAssertTrue(ThreadBuilder.piece(stopped, first: false, style: ThreadStyle(theme: theme)).text.string.contains("INTERRUPTED"))
    }

    func testTextWrapsWhereTheBarEndsAndWideTablesFitInside() throws {
        let coordinator = ChatThread.Coordinator(model: makeModel())
        let scroll = ChatThread.makeScrollView(coordinator)
        let text = try XCTUnwrap(coordinator.text)
        // In the bar AppKit doesn't keep the text in step with its clip view; only autoresizing runs, which keeps
        // the width the text was made with and adds the clip's growth. Without the clip's frame notifications it's the same here.
        scroll.contentView.postsFrameChangedNotifications = false
        text.frame.size.width = 600
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        let table = "| " + (1...8).map { "Column \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 8) + "\n| "
            + (1...8).map { _ in "`Sources/BoltbarNative/ThreadText.swift`" }.joined(separator: " | ") + " |"
        let reply = "Here:\n\n\(table)\n\nAfter the table, a paragraph long enough to need several lines still wraps where the bar ends.\n\n"
            + "- A list item long enough to wrap onto a second line\n\n> A quote that is also long enough to wrap onto another line\n\n```\nlet line = \"\(String(repeating: "x", count: 120))\"\n```"
        coordinator.update(messages: [Message(role: .user, text: "Compare them"), Message(role: .assistant, text: reply, author: "OpenAI")], theme: theme, revision: 0)
        scroll.frame.size.width = 900; scroll.frame.size.width = 500
        let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        layout.ensureLayout(for: container)
        let visible = scroll.contentView.bounds.width
        XCTAssertEqual(text.frame.width, visible, "The text is exactly as wide as what you see")
        var widest: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, used, _, _, _ in widest = max(widest, used.maxX) }
        XCTAssertLessThanOrEqual(widest, visible, "No line runs past the edge, a table's cells included")
    }

    func testARedrawOfPartOfATableKeepsItsBorders() throws {
        let coordinator = ChatThread.Coordinator(model: makeModel())
        let scroll = ChatThread.makeScrollView(coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        let rows = ["crossbow | 211.432", "docket | 1.020", "infra | 206", "knowledge | 198"].map { "| \($0) |" }.joined(separator: "\n")
        coordinator.update(messages: [Message(role: .user, text: "Lines per repo"),
                                      Message(role: .assistant, text: "| Repo | Lines |\n|---|---:|\n" + rows, author: "OpenAI")], theme: theme, revision: 0)
        let text = try XCTUnwrap(coordinator.text)
        let layout = try XCTUnwrap(text.layoutManager)
        func cell(_ substring: String) -> NSRect {
            layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: (text.string as NSString).range(of: substring).location), effectiveRange: nil)
        }
        /// Whether drawing only `rect`, as scrolling or a fading scroller does, paints anything there.
        func paints(_ rect: NSRect) throws -> Bool {
            let bitmap = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: rect))
            text.cacheDisplay(in: rect, to: bitmap)
            return (0..<bitmap.pixelsWide).contains { x in (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 } }
        }
        // Between two rows there is only padding and the border, no text.
        let between = NSRect(x: 0, y: cell("docket").maxY + 1, width: text.bounds.width, height: cell("infra").minY - cell("docket").maxY - 2)
        XCTAssertGreaterThan(between.height, 4)
        XCTAssertTrue(try paints(between), "The line between two rows is drawn")
        // Right of the last column's numbers: its padding and the table's right border.
        let number = cell("211.432")
        XCTAssertTrue(try paints(NSRect(x: number.maxX + 1, y: number.minY, width: text.bounds.width - number.maxX - 1, height: number.height)),
                      "The table's right border is drawn")
    }

    func testTheTextSizeScalesEveryPartOfTheThread() throws {
        let coordinator = ChatThread.Coordinator(model: makeModel())
        let scroll = ChatThread.makeScrollView(coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        let messages = [Message(role: .user, text: "Hi"),
                        Message(role: .assistant, text: "Body text\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| cell | 2 |", author: "OpenAI",
                                steps: [AgentStep(id: "s", kind: .command, title: "$ swift build", status: .done, at: 0)])]
        let text = try XCTUnwrap(coordinator.text)
        func size(_ substring: String) -> CGFloat? {
            (text.textStorage?.attribute(.font, at: (text.string as NSString).range(of: substring).location, effectiveRange: nil) as? NSFont)?.pointSize
        }
        coordinator.update(messages: messages, theme: theme, revision: 0)
        XCTAssertEqual(size("Body text"), 14); XCTAssertEqual(size("let x"), 12); XCTAssertEqual(size("$ swift"), 12)
        XCTAssertEqual(size("cell"), 13); XCTAssertEqual(size("OPENAI"), 9)
        coordinator.update(messages: messages, theme: theme, textSize: 21, revision: 0)
        XCTAssertEqual(size("Body text"), 21, "Every message is redrawn at the new size")
        XCTAssertEqual(size("let x"), 18); XCTAssertEqual(size("$ swift"), 18); XCTAssertEqual(size("cell"), 19.5); XCTAssertEqual(size("OPENAI"), 13.5)
    }

    func testCopyButtonsAppearBesideTheNameAndOnCodeBlocks() throws {
        let coordinator = ChatThread.Coordinator(model: makeModel())
        let scroll = ChatThread.makeScrollView(coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        coordinator.update(messages: [Message(role: .user, text: "Hi"),
                                      Message(role: .assistant, text: "Here:\n\n```swift\nlet x = 1\n```", author: "OpenAI")], theme: theme, revision: 0)
        let text = try XCTUnwrap(coordinator.text)
        let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        func point(of substring: String) -> NSPoint {
            let range = (text.string as NSString).range(of: substring)
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        let (message, code) = coordinator.copyButtons
        coordinator.hover(point(of: "Hi"))
        XCTAssertFalse(message.isHidden, "Your own messages can be copied too")
        XCTAssertEqual(message.imageScaling, .scaleNone, "The icon keeps its own size instead of filling the button")
        XCTAssertTrue(code.isHidden)
        let you = point(of: "YOU")
        XCTAssertGreaterThan(message.frame.minX, you.x)
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: (text.string as NSString).range(of: "YOU").location), effectiveRange: nil)
        XCTAssertGreaterThan(message.frame.midY, line.midY, "Centred on the name's letters, which sit low in their line")
        XCTAssertLessThan(message.frame.maxY, line.maxY + 1)
        coordinator.hover(point(of: "let x = 1"))
        XCTAssertFalse(code.isHidden, "A code block shows its own copy button")
        XCTAssertGreaterThan(code.frame.minX, 400)
        coordinator.hover(nil)
        XCTAssertTrue(message.isHidden && code.isHidden)
    }

    func testTheChatIsOneSelectableTextThatFollowsTheEnd() throws {
        let model = makeModel()
        let coordinator = ChatThread.Coordinator(model: model)
        let scroll = ChatThread.makeScrollView(coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 120)
        var messages = [Message(role: .user, text: "Hello"),
                        Message(role: .assistant, text: (1...40).map { "Line \($0)" }.joined(separator: "\n\n"), author: "OpenAI")]
        coordinator.update(messages: messages, theme: theme, revision: 0)
        let text = try XCTUnwrap(coordinator.text)
        XCTAssertTrue(text.string.hasPrefix("YOU\nHello\nOPENAI\n"))

        XCTAssertEqual(model.selectChat?(), true)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: (text.string as NSString).length), "⌘A takes the whole chat")

        let first = coordinator.pieces[0]
        messages[1].text += "\n\nMore"
        coordinator.update(messages: messages, theme: theme, revision: 0)
        XCTAssertTrue(coordinator.pieces[0] === first, "Streaming rebuilds only the reply it lands in")
        XCTAssertTrue(text.string.hasSuffix("More\n"))

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let clip = scroll.contentView
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        XCTAssertFalse(coordinator.following, "Scrolling up stops following the reply")
        clip.scroll(to: NSPoint(x: 0, y: text.frame.height - clip.bounds.height)); scroll.reflectScrolledClipView(clip)
        XCTAssertTrue(coordinator.following, "Back at the end, it follows again")

        coordinator.update(messages: [], theme: theme, revision: 1)
        XCTAssertEqual(text.string, "")
        XCTAssertEqual(model.selectChat?(), false, "Nothing to select in an empty chat")
    }
}
