import AppKit
import SwiftUI

// The chat thread as one native text view, so a selection can run across
// paragraphs and messages, ⌘A takes the whole chat and ⌘C keeps formatting.
// Each message is a piece of one attributed string; while a reply streams only
// its piece is rebuilt. Copy buttons and spinners float above the text.

extension NSAttributedString.Key {
    /// A fenced code block, whose rounded background the layout manager draws.
    static let boltbarCode = NSAttributedString.Key("boltbarCode")
    /// A quoted line, whose bar the layout manager draws.
    static let boltbarQuote = NSAttributedString.Key("boltbarQuote")
    /// A placeholder glyph where a spinner shows while something still runs.
    static let boltbarSpinner = NSAttributedString.Key("boltbarSpinner")
}

/// Marks one code block; equal only to itself, so neighbouring blocks stay apart.
final class CodeMark: NSObject {
    let color: NSColor
    init(color: NSColor) { self.color = color }
}

/// One message laid out as text, with the parts its copy buttons need.
final class ThreadPiece {
    let message: Message
    let first: Bool
    let text: NSAttributedString
    /// The name at the top; its copy button appears beside it.
    let label: NSRange
    let codeBlocks: [(range: NSRange, source: String)]
    init(message: Message, first: Bool, text: NSAttributedString, label: NSRange, codeBlocks: [(range: NSRange, source: String)]) {
        self.message = message; self.first = first; self.text = text; self.label = label; self.codeBlocks = codeBlocks
    }
}

struct ThreadStyle: Equatable {
    let theme: ThemePalette
    /// The sizes below are written for the standard text size; ⌘+ and ⌘− scale them all together.
    let scale: CGFloat
    init(theme: ThemePalette, textSize: Double = AppearancePreferences.standardTextSize) {
        self.theme = theme; scale = CGFloat(textSize / AppearancePreferences.standardTextSize)
    }
    var text: NSColor { theme.textNS }
    var secondary: NSColor { theme.textNS.withAlphaComponent(0.56) }
    var faint: NSColor { theme.textNS.withAlphaComponent(0.75) }
    var surface: NSColor { theme.textNS.withAlphaComponent(0.06) }
    var border: NSColor { theme.textNS.withAlphaComponent(0.12) }
    var accent: NSColor { theme.accentNS }
    var body: NSFont { system(14) }
    func size(_ points: CGFloat) -> CGFloat { points * scale }
    func system(_ points: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size(points), weight: weight) }
    func mono(_ points: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size(points), weight: weight) }
}

enum ThreadBuilder {
    typealias Attributes = [NSAttributedString.Key: Any]

    static func piece(_ message: Message, first: Bool, style: ThreadStyle) -> ThreadPiece {
        let out = NSMutableAttributedString()
        var codeBlocks: [(range: NSRange, source: String)] = []

        // The name, with room after it for the copy button before an Interrupted badge.
        let labelAttributes: Attributes = [.font: style.mono(9, .semibold), .kern: 1, .foregroundColor: style.secondary]
        let name = NSAttributedString(string: message.role == .user ? "YOU" : (message.author ?? "ASSISTANT").uppercased(), attributes: labelAttributes)
        let labelStyle = NSMutableParagraphStyle()
        labelStyle.minimumLineHeight = style.size(22); labelStyle.maximumLineHeight = style.size(22)
        labelStyle.paragraphSpacingBefore = style.size(first ? 6 : 22); labelStyle.paragraphSpacing = style.size(5)
        labelStyle.tabStops = [NSTextTab(textAlignment: .left, location: ceil(name.size().width) + style.size(36))]
        out.append(name)
        if message.interrupted == true { out.append(NSAttributedString(string: "\tINTERRUPTED", attributes: labelAttributes)) }
        out.append(NSAttributedString(string: "\n", attributes: labelAttributes))
        out.addAttribute(.paragraphStyle, value: labelStyle, range: NSRange(location: 0, length: out.length))

        if !message.attachments.isEmpty { out.append(attachments(message.attachments, style)) }
        // An agent's steps sit between the words written before and after them.
        for segment in MessageSegment.split(message.text, steps: message.steps ?? []) {
            switch segment {
            case .text(let source): appendMarkdown(source, to: out, codeBlocks: &codeBlocks, style: style)
            case .steps(let steps): steps.forEach { out.append(stepLine($0, style)) }
            }
        }
        if message.role == .assistant, !message.text.isEmpty {
            let sources = InlineMarkdown.sources(message.text)
            if !sources.isEmpty { out.append(sourcesLine(sources, style)) }
        }
        if message.text.isEmpty {
            if message.pending { out.append(statusLine(message.activity ?? "Thinking…", spinner: true, style)) }
            else if message.interrupted == true, message.steps?.isEmpty ?? true { out.append(statusLine("Stopped before the reply began.", spinner: false, style)) }
        }
        return ThreadPiece(message: message, first: first, text: out, label: NSRange(location: 0, length: name.length), codeBlocks: codeBlocks)
    }

    static func appendMarkdown(_ source: String, to out: NSMutableAttributedString, codeBlocks: inout [(range: NSRange, source: String)], style: ThreadStyle) {
        for block in MarkdownText.blocks(source) {
            if let table = block.table {
                out.append(tableText(table, style))
            } else if block.code {
                let start = out.length
                out.append(codeBlock(block, style))
                codeBlocks.append((NSRange(location: start, length: out.length - start), block.text))
            } else {
                block.text.components(separatedBy: "\n").forEach { out.append(lineText($0, style)) }
            }
        }
    }

    /// Paragraphs, headings, bullets and quotes, as MarkdownText draws them.
    static func lineText(_ line: String, _ style: ThreadStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.size(3); paragraph.paragraphSpacing = style.size(4)
        if line.isEmpty {
            return terminated(NSAttributedString(string: ""), font: style.system(4), paragraph)
        }
        if let marker = line.range(of: "^#{1,6} ", options: .regularExpression) {
            let level = CGFloat(line.distance(from: line.startIndex, to: marker.upperBound))
            let font = style.system(max(15, 23 - level), .semibold)
            paragraph.paragraphSpacingBefore = style.size(4)
            return terminated(inline(String(line[marker.upperBound...]), font: font, style: style), font: font, paragraph)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            paragraph.firstLineHeadIndent = style.size(4); paragraph.headIndent = style.size(20)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: style.size(20))]
            let bullet = NSMutableAttributedString(string: "•\t", attributes: [.font: style.body, .foregroundColor: style.secondary])
            bullet.append(inline(String(line.dropFirst(2)), font: style.body, style: style))
            return terminated(bullet, font: style.body, paragraph)
        }
        if line.hasPrefix("> ") {
            paragraph.firstLineHeadIndent = style.size(12); paragraph.headIndent = style.size(12)
            let quote = NSMutableAttributedString(attributedString: inline(String(line.dropFirst(2)), font: style.body, color: style.secondary, style: style))
            quote.addAttribute(.boltbarQuote, value: NSColor.gray.withAlphaComponent(0.5), range: NSRange(location: 0, length: quote.length))
            return terminated(quote, font: style.body, paragraph)
        }
        return terminated(inline(line, font: style.body, style: style), font: style.body, paragraph)
    }

    private static func terminated(_ text: NSAttributedString, font: NSFont, _ paragraph: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Inline Markdown with AppKit attributes: emphasis, code, links, and numeric citations as chips.
    static func inline(_ source: String, font: NSFont, color: NSColor? = nil, style: ThreadStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let out = NSMutableAttributedString()
        let plain: Attributes = [.font: font, .foregroundColor: color ?? style.text]
        var afterCitation = false
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            if let link = run.link, InlineMarkdown.isCitation(text, link) {
                // Consecutive chips need a real gap, or their tints merge into one.
                if afterCitation || out.string.last.map({ !$0.isWhitespace }) == true { out.append(NSAttributedString(string: " ", attributes: plain)) }
                out.append(chip(text, link: link, style)); afterCitation = true
                continue
            }
            if afterCitation, let first = text.first, CitationSpacing.separates(first) { out.append(NSAttributedString(string: " ", attributes: plain)) }
            var attributes = plain
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: max(style.size(10), runFont.pointSize - style.size(1)), weight: .regular); attributes[.backgroundColor] = style.surface }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = runFont
            if let link = run.link {
                attributes[.link] = link; attributes[.foregroundColor] = style.accent; attributes[.toolTip] = link.absoluteString
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue; attributes[.underlineColor] = style.accent.withAlphaComponent(0.55)
            }
            out.append(NSAttributedString(string: text, attributes: attributes)); afterCitation = false
        }
        return out
    }

    static func chip(_ label: String, link: URL, _ style: ThreadStyle) -> NSAttributedString {
        NSAttributedString(string: "\u{2009}\(label)\u{2009}", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: style.size(11), weight: .semibold), .foregroundColor: style.accent,
            .backgroundColor: style.accent.withAlphaComponent(0.16), .baselineOffset: style.size(1), .link: link, .toolTip: link.absoluteString,
        ])
    }

    /// Long lines wrap: a selectable chat can't also scroll each block sideways.
    static func codeBlock(_ block: MarkdownText.Block, _ style: ThreadStyle) -> NSAttributedString {
        func paragraph(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = style.size(12); paragraph.headIndent = style.size(12); paragraph.tailIndent = -style.size(12)
            paragraph.paragraphSpacingBefore = style.size(before); paragraph.paragraphSpacing = style.size(after)
            return paragraph
        }
        let out = NSMutableAttributedString(string: (block.language.isEmpty ? "Code" : block.language) + "\n",
                                            attributes: [.font: style.mono(10), .foregroundColor: style.secondary, .paragraphStyle: paragraph(before: 18, after: 6)])
        let code = MarkdownText.highlightedNS(block.text, theme: style.theme, size: style.size(12))
        code.append(NSAttributedString(string: "\n", attributes: [.font: style.mono(12)]))
        code.addAttribute(.paragraphStyle, value: paragraph(before: 0, after: 0), range: NSRange(location: 0, length: code.length))
        let lastLine = (code.string as NSString).lineRange(for: NSRange(location: max(0, code.length - 1), length: 0))
        code.addAttribute(.paragraphStyle, value: paragraph(before: 0, after: 18), range: lastLine)
        out.append(code)
        out.addAttribute(.boltbarCode, value: CodeMark(color: style.surface), range: NSRange(location: 0, length: out.length))
        return out
    }

    static func tableText(_ table: MarkdownTable, _ style: ThreadStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: spacer(style.size(6)))
        let textTable = NSTextTable()
        textTable.numberOfColumns = table.headers.count; textTable.collapsesBorders = true
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        for (row, cells) in ([table.headers] + table.rows).enumerated() {
            for (column, cell) in cells.enumerated() {
                let block = NSTextTableBlock(table: textTable, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(style.border); block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(style.size(7), type: .absoluteValueType, for: .padding)
                if row == 0 { block.backgroundColor = style.surface }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                switch table.alignments[min(column, table.alignments.count - 1)] {
                case .leading: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }
                let font = row == 0 ? style.system(13, .semibold) : style.system(13)
                let text = NSMutableAttributedString(attributedString: inline(cell, font: font, style: style))
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                out.append(text)
            }
        }
        out.append(spacer(style.size(6)))
        return out
    }

    private static func spacer(_ height: CGFloat) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: height)])
    }

    static func stepLine(_ step: AgentStep, _ style: ThreadStyle) -> NSAttributedString {
        let font = style.mono(12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = style.size(4); paragraph.headIndent = style.size(22)
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: style.size(22))]
        let (glyph, color): (String, NSColor) = {
            switch step.status {
            case .running: return ("◌", .clear)
            case .done: return (step.kind == .edit ? "✎" : "✓", style.secondary)
            case .failed: return ("✕", style.theme.errorNS)
            case .denied: return ("⊘", style.secondary)
            }
        }()
        var glyphAttributes: Attributes = [.font: style.system(13, .medium), .foregroundColor: color, .baselineOffset: -style.size(0.5)]
        if step.status == .running { glyphAttributes[.boltbarSpinner] = true }
        let out = NSMutableAttributedString(string: glyph, attributes: glyphAttributes)
        out.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        var title: Attributes = [.font: font, .foregroundColor: step.status == .running ? style.text : style.faint]
        if step.status == .denied { title[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        out.append(NSAttributedString(string: step.title, attributes: title))
        if let detail = step.status == .denied ? "declined" : step.detail {
            out.append(NSAttributedString(string: "  " + detail, attributes: [.font: font, .foregroundColor: style.secondary]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func statusLine(_ text: String, spinner: Bool, _ style: ThreadStyle) -> NSAttributedString {
        let font = style.mono(13)
        let out = NSMutableAttributedString()
        if spinner {
            out.append(NSAttributedString(string: "◌", attributes: [.font: font, .foregroundColor: NSColor.clear, .boltbarSpinner: true]))
            out.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }
        out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: style.secondary]))
        return out
    }

    /// Numbered sources under an answer, grouped by site: "1 2 swift.org".
    static func sourcesLine(_ sources: [InlineMarkdown.Source], _ style: ThreadStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "SOURCES", attributes: [.font: style.mono(9, .semibold), .kern: 1, .foregroundColor: style.text.withAlphaComponent(0.55)])
        var domains: [String] = []
        for source in sources where !domains.contains(source.domain) { domains.append(source.domain) }
        let gap: Attributes = [.font: style.mono(11)]
        for domain in domains {
            let group = sources.filter { $0.domain == domain }
            out.append(NSAttributedString(string: "   ", attributes: gap))
            for source in group { out.append(chip(String(source.number), link: source.url, style)); out.append(NSAttributedString(string: " ", attributes: gap)) }
            out.append(NSAttributedString(string: domain, attributes: [.font: style.mono(11), .foregroundColor: style.accent, .link: group[0].url, .toolTip: group[0].url.absoluteString]))
        }
        out.append(NSAttributedString(string: "\n", attributes: gap))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.size(5); paragraph.paragraphSpacingBefore = style.size(4)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func attachments(_ items: [Attachment], _ style: ThreadStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for item in items {
            if let image = item.image {
                let attachment = NSTextAttachment()
                let height = style.size(64)
                let size = image.size.height > 0 ? NSSize(width: min(style.size(120), image.size.width * height / image.size.height), height: height) : NSSize(width: height, height: height)
                attachment.image = NSImage(size: size, flipped: false) { rect in
                    NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
                    image.draw(in: rect); return true
                }
                attachment.bounds = NSRect(origin: .zero, size: size)
                out.append(NSAttributedString(attachment: attachment))
            } else {
                let symbol = NSImage(systemSymbolName: item.isPDF ? "doc.richtext" : "doc.text", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: style.size(13), weight: .regular).applying(.init(paletteColors: [style.accent])))
                if let symbol {
                    let attachment = NSTextAttachment(); attachment.image = symbol
                    attachment.bounds = NSRect(x: 0, y: -style.size(2), width: symbol.size.width, height: symbol.size.height)
                    out.append(NSAttributedString(attachment: attachment))
                }
                out.append(NSAttributedString(string: " " + item.name, attributes: [.font: style.mono(11, .medium), .foregroundColor: style.text]))
                out.append(NSAttributedString(string: "  " + ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file),
                                              attributes: [.font: style.mono(10), .foregroundColor: style.secondary]))
            }
            out.append(NSAttributedString(string: "   ", attributes: [.font: style.body]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: style.body]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = style.size(6)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// Draws what attributes can't: rounded code-block backgrounds across the full width, and quote bars.
final class ThreadLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first, storage.length > 0 {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let all = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.boltbarCode, in: characters) { value, range, _ in
                guard let mark = value as? CodeMark else { return }
                var block = NSRange()
                _ = storage.attribute(.boltbarCode, at: range.location, longestEffectiveRange: &block, in: all)
                let rect = blockRect(block, container: container).offsetBy(dx: origin.x, dy: origin.y)
                mark.color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }
            storage.enumerateAttribute(.boltbarQuote, in: characters) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let bounds = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                color.setFill()
                NSRect(x: origin.x + 2, y: origin.y + bounds.minY, width: 2, height: bounds.height).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
    /// A code block's box: its lines' used area, padded, across the container.
    func blockRect(_ characters: NSRange, container: NSTextContainer) -> NSRect {
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: characters, actualCharacterRange: nil)) { _, used, _, _, _ in
            top = min(top, used.minY); bottom = max(bottom, used.maxY)
        }
        guard top <= bottom else { return .zero }
        return NSRect(x: 0, y: top - 8, width: container.size.width, height: bottom - top + 16)
    }
}

final class ThreadTextView: NSTextView {
    var onHover: ((NSPoint?) -> Void)?
    var onEscape: (() -> Void)?
    var onType: ((NSEvent) -> Void)?
    var onTextSize: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    /// Exactly as wide as what you see, so every line wraps at the bar's edge. Autoresizing alone keeps
    /// the width the view was made with and only adds the clip view's growth, which cut off whole replies.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: (superview as? NSClipView)?.bounds.width ?? newSize.width, height: newSize.height))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(nil) }
    /// Typing while the chat has focus goes to the message field; Esc goes back to it.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if let step = TextSizeKey.step(event), let onTextSize { onTextSize(step); return }
        let navigation: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, !navigation.contains(event.keyCode),
           let characters = event.characters, !characters.isEmpty {
            onType?(event); return
        }
        super.keyDown(with: event)
    }
}

/// The thread, bridged to SwiftUI.
struct ChatThread: NSViewRepresentable {
    @ObservedObject var model: ChatModel
    let theme: ThemePalette
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(context.coordinator) }
    /// The scroll view and text view, attached to a coordinator; tests build it the same way.
    static func makeScrollView(_ coordinator: Coordinator) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = ThreadLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let text = ThreadTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 44), textContainer: container)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.textContainerInset = .zero; text.usesFontPanel = false; text.isAutomaticLinkDetectionEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        text.setAccessibilityLabel("Conversation")
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = text
        coordinator.attach(scroll: scroll, text: text)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(messages: model.messages, theme: theme, textSize: model.appearance.chatTextSize, revision: model.threadRevision)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ChatModel
        private weak var scroll: NSScrollView?
        private(set) weak var text: ThreadTextView?
        private(set) var pieces: [ThreadPiece] = []
        private var cache: [UUID: ThreadPiece] = [:]
        private var style: ThreadStyle?
        private var revision = -1, count = 0
        private(set) var following = true
        private let copyMessage = CopyOverlay(), copyCode = CopyOverlay()
        private var spinners: [NSProgressIndicator] = []
        init(model: ChatModel) { self.model = model }

        func attach(scroll: NSScrollView, text: ThreadTextView) {
            self.scroll = scroll; self.text = text
            text.delegate = self
            text.addSubview(copyMessage.button); text.addSubview(copyCode.button)
            text.onHover = { [weak self] point in self?.hover(point) }
            text.onTextSize = { [weak self] step in self?.model.stepTextSize(step) }
            text.onEscape = { [weak self, weak text] in
                text?.setSelectedRange(NSRange(location: 0, length: 0)); self?.model.focusComposer?()
            }
            text.onType = { [weak self, weak text] event in
                self?.model.focusComposer?()
                if let responder = text?.window?.firstResponder, responder !== text { responder.keyDown(with: event) }
            }
            model.selectChat = { [weak text] in
                guard let text, let storage = text.textStorage, storage.length > 0 else { return false }
                text.window?.makeFirstResponder(text); text.selectAll(nil); return true
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            text.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: text)
        }

        func update(messages: [Message], theme: ThemePalette, textSize: Double = AppearancePreferences.standardTextSize, revision: Int) {
            guard let text, let storage = text.textStorage, let layout = text.layoutManager, let container = text.textContainer else { return }
            let style = ThreadStyle(theme: theme, textSize: textSize)
            // A new theme or text size redraws every message.
            if style != self.style {
                self.style = style; cache = [:]; pieces = []
                storage.setAttributedString(NSAttributedString())
                text.selectedTextAttributes = [.backgroundColor: theme.accentNS.withAlphaComponent(0.25)]
                copyMessage.colors(style.secondary, copied: style.accent); copyCode.colors(style.secondary, copied: style.accent)
            }
            let fresh = messages.enumerated().map { index, message -> ThreadPiece in
                if let cached = cache[message.id], cached.first == (index == 0), cached.message.sameContent(as: message) { return cached }
                let piece = ThreadBuilder.piece(message, first: index == 0, style: style)
                cache[message.id] = piece
                return piece
            }
            var same = 0
            while same < min(pieces.count, fresh.count), pieces[same] === fresh[same] { same += 1 }
            let changed = same < pieces.count || same < fresh.count
            // SwiftUI asks on every keystroke in the field; with nothing new, there's nothing to do.
            guard changed || revision != self.revision else { return }
            if changed {
                let location = pieces[..<same].reduce(0) { $0 + $1.text.length }
                let length = pieces[same...].reduce(0) { $0 + $1.text.length }
                let replacement = NSMutableAttributedString()
                fresh[same...].forEach { replacement.append($0.text) }
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
                storage.endEditing()
                pieces = fresh
                cache = cache.filter { id, _ in messages.contains { $0.id == id } }
            }
            layout.ensureLayout(for: container)
            text.sizeToFit()
            let height = ceil(layout.usedRect(for: container).height) + 2
            if abs(model.threadHeight - height) > 0.5 { DispatchQueue.main.async { [model] in model.threadHeight = height } }
            // New messages, an opened chat, or a reply growing while you're at the end keep the end in view.
            if messages.count != count || revision != self.revision || following {
                following = true
                DispatchQueue.main.async { [weak self] in self?.scrollToEnd() }
            }
            count = messages.count; self.revision = revision
            placeSpinners()
            if copyMessage.piece != nil || copyCode.piece != nil { hover(lastHover) }
        }

        private var lastHover: NSPoint?
        var copyButtons: (message: NSButton, code: NSButton) { (copyMessage.button, copyCode.button) }
        /// Shows the copy buttons for what's under the pointer: the message's, beside its name, and a code block's.
        func hover(_ point: NSPoint?) {
            lastHover = point
            guard let point, let text, let layout = text.layoutManager, let container = text.textContainer, let style,
                  let storage = text.textStorage, storage.length > 0 else { copyMessage.hide(); copyCode.hide(); return }
            let origin = text.textContainerOrigin
            let index = layout.characterIndex(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            var start = 0
            for piece in pieces {
                let range = NSRange(location: start, length: piece.text.length)
                if NSLocationInRange(index, range) || index == range.upperBound && piece === pieces.last {
                    if !piece.message.text.isEmpty {
                        let labelRange = NSRange(location: start + piece.label.location, length: piece.label.length)
                        let label = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: labelRange, actualCharacterRange: nil), in: container)
                        // The name sits at the bottom of a 22 pt line: centre the icon on its capitals, not on the line.
                        let glyph = layout.glyphIndexForCharacter(at: labelRange.location)
                        let baseline = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y
                        let middle = baseline - style.mono(9, .semibold).capHeight / 2
                        copyMessage.show(piece: piece, text: piece.message.text, label: piece.message.role == .user ? "Copy message" : "Copy response",
                                         at: NSPoint(x: origin.x + label.maxX + 6, y: origin.y + middle - CopyOverlay.size.height / 2))
                    } else { copyMessage.hide() }
                    if let block = piece.codeBlocks.first(where: { NSLocationInRange(index - start, $0.range) }), let layout = layout as? ThreadLayoutManager {
                        let rect = layout.blockRect(NSRange(location: start + block.range.location, length: block.range.length), container: container)
                        copyCode.show(piece: piece, text: block.source, label: "Copy code", at: NSPoint(x: origin.x + rect.maxX - 28, y: origin.y + rect.minY + 6))
                    } else { copyCode.hide() }
                    return
                }
                start += piece.text.length
            }
            copyMessage.hide(); copyCode.hide()
        }

        /// A small spinner over each running step and pending reply.
        private func placeSpinners() {
            guard let text, let storage = text.textStorage, let layout = text.layoutManager, let container = text.textContainer else { return }
            var rects: [NSRect] = []
            storage.enumerateAttribute(.boltbarSpinner, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                rects.append(layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container))
            }
            while spinners.count < rects.count {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
                text.addSubview(spinner); spinners.append(spinner)
            }
            let origin = text.textContainerOrigin
            for (index, spinner) in spinners.enumerated() {
                if index < rects.count {
                    let rect = rects[index]
                    spinner.frame = NSRect(x: origin.x + rect.midX - 6, y: origin.y + rect.midY - 6, width: 12, height: 12)
                    spinner.isHidden = false; spinner.startAnimation(nil)
                } else { spinner.stopAnimation(nil); spinner.isHidden = true }
            }
        }

        private func scrollToEnd() {
            guard let scroll, let text else { return }
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, text.frame.height - clip.bounds.height)))
            scroll.reflectScrolledClipView(clip)
        }
        private var clipSize = NSSize.zero
        /// Only a real scroll changes whether the end stays in view; the panel growing or shrinking doesn't.
        @objc private func scrolled() {
            guard let scroll, let text else { return }
            let clip = scroll.contentView.bounds
            if clip.size != clipSize { clipSize = clip.size; if following { scrollToEnd() }; return }
            following = clip.maxY >= text.frame.height - 24
        }
        @objc private func resized() {
            placeSpinners()
            if following { scrollToEnd() }
            if let text, let layout = text.layoutManager, let container = text.textContainer {
                let height = ceil(layout.usedRect(for: container).height) + 2
                if abs(model.threadHeight - height) > 0.5 { DispatchQueue.main.async { [model] in model.threadHeight = height } }
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if !model.openLink(url) { NSWorkspace.shared.open(url) }
            return true
        }
    }
}

/// A copy button that floats over the text, beside a message's name or atop a code block.
@MainActor final class CopyOverlay: NSObject {
    static let size = NSSize(width: 20, height: 18)
    let button = NSButton()
    private(set) var piece: ThreadPiece?
    private var text = ""
    private var reset: DispatchWorkItem?
    // The theme's colours, not the system's: the panel's look follows Boltbar's theme.
    private var tint = NSColor.secondaryLabelColor, copiedTint = NSColor.controlAccentColor
    func colors(_ tint: NSColor, copied: NSColor) {
        self.tint = tint; copiedTint = copied
        button.contentTintColor = reset == nil ? tint : copied
    }
    override init() {
        super.init()
        button.isBordered = false; button.bezelStyle = .inline; button.isHidden = true
        // Borderless buttons stretch their image to the frame; keep the symbol at its own size.
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly; button.contentTintColor = .secondaryLabelColor
        button.target = self; button.action = #selector(copyText)
        setImage("doc.on.doc")
    }
    func show(piece: ThreadPiece, text: String, label: String, at point: NSPoint) {
        self.piece = piece; self.text = text
        button.frame = NSRect(origin: point, size: Self.size)
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.isHidden = false
    }
    func hide() { if reset == nil { button.isHidden = true; piece = nil } }
    private func setImage(_ name: String) {
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    }
    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setImage("checkmark"); button.toolTip = "Copied"; button.contentTintColor = copiedTint
        reset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            setImage("doc.on.doc"); button.contentTintColor = tint; reset = nil
        }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
