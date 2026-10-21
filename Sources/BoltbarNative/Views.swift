import AppKit
import SwiftUI

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct AttachmentTile: View {
    @Environment(\.boltbarTheme) private var theme
    private var accent: Color { theme.accent }
    let attachment: Attachment
    var remove: (() -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        Group {
            if let image = attachment.image {
                Button { expanded.toggle() } label: {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 72, height: 64).clipped()
                }.buttonStyle(.plain).accessibilityLabel(attachment.name)
                    .popover(isPresented: $expanded) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 450).padding(8) }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: attachment.isPDF ? "doc.richtext" : "doc.text").font(.system(size: 22, design: .monospaced)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.name).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }.padding(10).frame(width: 160, height: 44)
            }
        }
        .background(theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold, design: .monospaced)).frame(width: 20, height: 20).background(theme.background, in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)").offset(x: 3, y: -3)
            }
        }
    }
}

struct AttachmentStrip: View {
    let items: [Attachment]
    var remove: ((UUID) -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) { ForEach(items) { item in AttachmentTile(attachment: item, remove: remove.map { action in { action(item.id) } }) } }.padding(4)
        }.frame(height: 74)
    }
}

/// A reply read in order: text, then the steps taken at that point, then more text.
enum MessageSegment {
    case text(String), steps([AgentStep])
    static func split(_ text: String, steps: [AgentStep]) -> [MessageSegment] {
        guard !steps.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        var result: [MessageSegment] = [], group: [AgentStep] = [], cursor = text.startIndex
        func flushText(upTo end: String.Index) {
            let chunk = text[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(.text(chunk)) }
            cursor = end
        }
        for step in steps {
            let end = text.index(text.startIndex, offsetBy: max(0, step.at ?? 0), limitedBy: text.endIndex) ?? text.endIndex
            if end > cursor {
                if !group.isEmpty { result.append(.steps(group)); group = [] }
                flushText(upTo: end)
            }
            group.append(step)
        }
        if !group.isEmpty { result.append(.steps(group)) }
        flushText(upTo: text.endIndex)
        return result
    }
}

/// Pending messages sit between the thread and the composer, in send order, so
/// text written during a reply always stays visible with its state.
struct QueuePanel: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    private var status: String {
        if model.editingQueuedID != nil { return "Paused while you edit · Esc cancels" }
        if model.queueHeld { return "Paused" }
        return model.queue.count > 1 ? "Sent together when this reply finishes" : "Sends when this reply finishes"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.queue.count > 1 ? "QUEUED · \(model.queue.count)" : "QUEUED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                Text(status).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if model.editingQueuedID == nil {
                    Button { model.sendQueueNow() } label: {
                        Text(model.hasDraft ? "Send now" : "Send now ↵").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.accent)
                            .padding(.horizontal, 8).frame(height: 22).background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .help(model.streaming ? "Interrupt this reply and send the queue now" : "Send the queue now")
                }
            }.frame(height: 22)
            ForEach(model.queue) { message in row(message) }
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
    }
    private func row(_ message: Message) -> some View {
        let editing = model.editingQueuedID == message.id
        let canEdit = model.editingQueuedID == nil && !model.hasDraft
        let summary = message.text.isEmpty ? message.attachments.map(\.name).joined(separator: ", ")
            : message.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return HStack(spacing: 8) {
            // Not .disabled: that would grey out the queue whenever the user types.
            Button { model.editQueued(message.id) } label: {
                HStack(spacing: 6) {
                    if editing { Image(systemName: "pencil").foregroundStyle(theme.accent) }
                    Text(summary).lineLimit(1).truncationMode(.tail)
                    if !message.attachments.isEmpty {
                        Label("\(message.attachments.count)", systemImage: "paperclip").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 12, design: .monospaced)).frame(height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .opacity(model.editingQueuedID == nil || editing ? 1 : 0.5)
                .help(editing ? "Editing in the message field" : canEdit ? "Edit" : model.editingQueuedID != nil ? "Finish the current edit first" : "Clear the message field to edit")
                .accessibilityLabel("Queued message: \(summary)").accessibilityHint(canEdit ? "Edit" : "")
            Button { model.removeQueued(message.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary).frame(width: 22, height: 22)
            }.buttonStyle(.plain).help("Remove from queue").accessibilityLabel("Remove queued message")
        }
    }
}

/// Keep the hit target and layout stable while revealing the action on hover
/// or keyboard focus. Copy the original Markdown, including links and fences.
struct CopyIconButton: View {
    @Environment(\.boltbarTheme) private var theme
    private var accent: Color { theme.accent }
    let text: String
    let label: String
    var visible = true
    @State private var copied = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(copied ? accent : .secondary)
                .frame(width: 24, height: 22)
                .background(theme.text.opacity(hovering || focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).focused($focused)
            .opacity(visible || focused || copied ? 1 : 0)
            .onHover { hovering = $0 }
            .help(copied ? "Copied" : label)
            .accessibilityLabel(copied ? "Copied" : label)
            .accessibilityHidden(false)
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = false } catch { }
            }
    }
}

struct ChatBar: View {
    @Environment(\.boltbarTheme) private var theme
    private var accent: Color { theme.accent }
    @ObservedObject var model: ChatModel
    var body: some View {
        VStack(spacing: 10) {
            PanelMoveArea().frame(height: 12)
            if model.showingHistory {
                HistoryPane(model: model, close: { model.closeHistory() })
            } else {
            if model.showingHelp {
                HelpPane(model: model)
                Rectangle().fill(theme.border).frame(height: 1)
            } else if !model.messages.isEmpty {
                // One native text view: select across messages, ⌘A for the whole chat, ⌘C with formatting.
                ChatThread(model: model, theme: theme)
                    .frame(height: model.manualThreadHeight ?? min(330, max(44, model.threadHeight)))
                Rectangle().fill(theme.border).frame(height: 1)
            }
            if !model.queue.isEmpty { QueuePanel(model: model) }
            if let approval = model.pendingApproval { ApprovalCard(model: model, request: approval) }
            if let matches = slashMatches { SlashMenu(matches: matches) }
            if !model.attachments.isEmpty {
                AttachmentStrip(items: model.attachments) { id in model.attachments.removeAll { $0.id == id } }
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text(placeholder).font(.system(size: 15, design: .monospaced)).foregroundStyle(.gray).padding(.top, 2).allowsHitTesting(false) }
                GrowingEditor(model: model).onAppear { DispatchQueue.main.async { model.focusComposer?() } }
            }.frame(height: model.inputHeight)
                .overlay(alignment: .topTrailing) {
                    if let hint = returnHint {
                        Text(hint).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 4).allowsHitTesting(false)
                    }
                }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.error).fixedSize(horizontal: false, vertical: true).padding(8).background(theme.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 0)
                    if !model.messages.isEmpty { Button("Retry") { model.retry() }.font(.system(size: 12, design: .monospaced)).buttonStyle(.borderless) }
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
            } else if let notice = model.notice {
                Text(notice).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            // The two chips that say how it will answer come first; + unrolls the rest.
            HStack(spacing: 9) {
                Button { model.selectingModel = false; model.selectingAgent = false; model.showingAgentPicker = false; model.showingModelPicker.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(model.selectedModelReady ? modelTitle(model.model) : "Choose model").lineLimit(1)
                        EffortGauge(effort: model.preferences.effort).frame(width: 18, height: 16).accessibilityHidden(true)
                    }
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.horizontal, 11).frame(height: 29).background(theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(model.selectingModel ? accent : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain).accessibilityLabel("Effort and model")
                    .accessibilityValue("\(modelTitle(model.model)), \(model.preferences.effort.title) effort")
                    .help("\(model.preferences.effort.title) effort")
                    .popover(isPresented: $model.showingModelPicker, arrowEdge: .top) { ModelPopover(model: model, close: { model.showingModelPicker = false }) }
                AgentChip(model: model)
                ToolRoll(model: model)
                PanelMoveArea().frame(maxWidth: .infinity).frame(height: 31)
                // With text during a reply the main button queues it, so Stop
                // stays available beside it instead of hiding behind it.
                let stops = model.streaming && !model.hasDraft
                if model.streaming && model.hasDraft {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 31, height: 31).background(theme.surface, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Stop").help("Stop this reply")
                }
                Button { if stops { model.stop() } else { model.send() } } label: {
                    Image(systemName: stops ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .frame(width: 31, height: 31).background(accent, in: Circle()).foregroundStyle(theme.onAccent)
                }.buttonStyle(.plain).accessibilityLabel(stops ? "Stop" : model.streaming ? "Add to queue" : "Send")
                    .help(stops ? "Stop this reply" : model.streaming ? "Queue · sends when this reply finishes" : "Send")
            }
            }
            if let error = model.historyError {
                Text(error).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.error).fixedSize(horizontal: false, vertical: true).padding(8).background(theme.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 14)
        .frame(width: model.panelWidth).background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .overlay(PanelBorders(model: model))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { model.resize?($0) }
    }
}

extension ChatBar {
    private var placeholder: String {
        if model.editingQueuedID != nil { return "Edit queued message…" }
        if model.streaming || !model.queue.isEmpty { return "Queue a follow-up…" }
        if model.agentMode, let project = model.agentProject { return "Tell it what to do in \(model.agentSettings.displayName(project))…" }
        return "Ask anything…"
    }
    /// Typing / lists the local commands; Tab completes the first.
    private var slashMatches: [(command: String, summary: String)]? {
        let text = model.draft.lowercased()
        guard text.hasPrefix("/"), !text.contains(" "), model.attachments.isEmpty else { return nil }
        let matches = HelpContent.commands.filter { $0.command.hasPrefix(text) && $0.command != text || $0.command == text }
        return matches.isEmpty ? nil : matches
    }
    /// Return's meaning changes with an empty composer and a queue; say so
    /// where the user is looking instead of relying on the shortcut alone.
    private var returnHint: String? {
        guard model.draft.isEmpty, !model.queue.isEmpty, model.editingQueuedID == nil else { return nil }
        return model.streaming ? "↵ interrupt and send" : "↵ send queued"
    }
}

struct EffortGauge: View {
    @Environment(\.boltbarTheme) private var theme
    private var accent: Color { theme.accent }
    let effort: Effort
    private var angle: Double { switch effort { case .low: return -150; case .medium: return -90; case .high: return -30 } }
    var body: some View {
        ZStack {
            Path { path in
                path.addArc(center: CGPoint(x: 9, y: 12), radius: 7.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            }.stroke(theme.text.opacity(0.45), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            Path { path in
                path.move(to: CGPoint(x: 9, y: 12))
                let radians = angle * .pi / 180
                path.addLine(to: CGPoint(x: 9 + cos(radians) * 6, y: 12 + sin(radians) * 6))
            }.stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            Circle().fill(accent).frame(width: 3, height: 3).position(x: 9, y: 12)
        }
    }
}

struct ModelPopover: View {
    @Environment(\.boltbarTheme) private var theme
    private var accent: Color { theme.accent }
    @ObservedObject var model: ChatModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thinking effort").font(.system(size: 12, weight: .medium, design: .monospaced))
            HStack(spacing: 3) {
                ForEach(Effort.allCases, id: \.self) { effort in
                    Button { model.preferences.effort = effort } label: {
                        Text(effort.title).font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(model.preferences.effort == effort ? accent : theme.text.opacity(0.6))
                            .background(model.preferences.effort == effort ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityLabel("\(effort.title) effort")
                        .accessibilityAddTraits(model.preferences.effort == effort ? .isSelected : [])
                }
            }.padding(3).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.selectableModels.isEmpty {
                        Text("Connect a provider in Settings to choose models.").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    ForEach(model.selectableModels) { choice in
                        Button { model.selectModel(choice); close() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(modelTitle(choice.model)).lineLimit(1)
                                    Text(choice.provider.title).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.provider == choice.provider && model.model == choice.model { Image(systemName: "checkmark").foregroundStyle(accent) }
                            }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 7).padding(.horizontal, 6)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 280)
            Button("Provider settings…") { close(); model.openSettings?() }.font(.system(size: 11, design: .monospaced)).buttonStyle(.borderless)
        }.padding(16).frame(width: 280).background(theme.background)
    }
}

struct MarkdownText: View {
    @Environment(\.boltbarTheme) private var theme
    private var accent: Color { theme.accent }
    let source: String
    struct Block { var text: String; var code: Bool; var language: String = ""; var table: MarkdownTable? = nil }
    static func blocks(_ source: String) -> [Block] {
        var result: [Block] = [], text = "", code = false, language = ""
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if !text.isEmpty { result.append(Block(text: text.trimmingCharacters(in: .newlines), code: code, language: language)) }; text = ""
                code.toggle(); language = code ? String(line.dropFirst(3)) : ""
            } else { text += line + "\n" }
        }
        if !text.isEmpty { result.append(Block(text: text.trimmingCharacters(in: .newlines), code: code, language: language)) }
        return result.flatMap { block -> [Block] in
            guard !block.code else { return [block] }
            let lines = block.text.components(separatedBy: "\n")
            var blocks: [Block] = [], pending: [String] = [], index = 0
            while index < lines.count {
                if let parsed = MarkdownTable.parse(lines, at: index) {
                    if !pending.isEmpty { blocks.append(Block(text: pending.joined(separator: "\n"), code: false)); pending = [] }
                    blocks.append(Block(text: lines[index..<parsed.end].joined(separator: "\n"), code: false, table: parsed.table))
                    index = parsed.end
                } else { pending.append(lines[index]); index += 1 }
            }
            if !pending.isEmpty { blocks.append(Block(text: pending.joined(separator: "\n"), code: false)) }
            return blocks
        }
    }
    static func highlighted(_ source: String, theme: ThemePalette = ThemeName.graphite.palette) -> AttributedString {
        AttributedString(highlightedNS(source, theme: theme))
    }
    static func highlightedNS(_ source: String, theme: ThemePalette = ThemeName.graphite.palette) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [.foregroundColor: theme.textNS, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let rules: [(String, NSColor)] = [
            (#"\b(let|var|func|fn|struct|class|enum|import|use|return|if|else|for|while|async|await|def|const|function|true|false|nil|null|public|private|static|throw|try)\b"#, NSColor(hex: theme.dark ? "C6A0E8" : "7651A8")!),
            (#"\b[0-9]+(?:\.[0-9]+)?\b"#, NSColor(hex: theme.dark ? "E5BB88" : "986020")!),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, NSColor(hex: theme.dark ? "A0CCB8" : "39735C")!),
            (#"(?m)//[^\n]*|^[ \t]*#[^\n]*"#, NSColor(hex: theme.dark ? "A1A6B3" : "656968")!),
        ]
        for (pattern, color) in rules {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) { result.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                if let table = block.table {
                    MarkdownTableView(table: table)
                } else if block.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(block.language.isEmpty ? "Code" : block.language).foregroundStyle(.secondary); Spacer(); CopyIconButton(text: block.text, label: "Copy code") }.font(.system(size: 10, design: .monospaced))
                        ScrollView(.horizontal) { Text(Self.highlighted(block.text, theme: theme)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                    }.padding(10).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(block.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            MarkdownLine(line: line)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).tint(accent)
    }
}

/// Inline Markdown with links that read as links in every theme. Numeric web
/// citations become compact tinted chips, kept apart from neighbouring words
/// even in chats saved before streaming separated them. Descriptive links keep
/// their words and gain an underline, so neither depends on colour alone.
enum InlineMarkdown {
    struct Source: Equatable { let number: Int; let url: URL; let domain: String }
    static func isCitation(_ label: String, _ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return (1...3).contains(label.count) && label.allSatisfy { $0.isASCII && $0.isNumber }
    }
    static func chip(_ label: String, accent: Color, attributes: AttributeContainer = AttributeContainer()) -> AttributedString {
        var chip = AttributedString("\u{2009}\(label)\u{2009}", attributes: attributes)
        chip.swiftUI.font = .system(size: 11, weight: .semibold).monospacedDigit()
        chip.swiftUI.backgroundColor = accent.opacity(0.16)
        chip.swiftUI.baselineOffset = 1
        return chip
    }
    static func render(_ source: String, accent: Color) -> AttributedString {
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        var result = AttributedString(), afterCitation = false
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            let text = String(piece.characters)
            if isCitation(text, run.link) {
                // Consecutive chips need a real gap, or their tints merge into one.
                if afterCitation || result.characters.last.map({ !$0.isWhitespace }) == true { result += AttributedString(" ") }
                result += chip(text, accent: accent, attributes: run.attributes); afterCitation = true
                continue
            }
            if afterCitation, let first = text.first, CitationSpacing.separates(first) { result += AttributedString(" ") }
            if run.link != nil { piece.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: accent.opacity(0.55)) }
            result += piece; afterCitation = false
        }
        return result
    }
    /// Numbered sources in citation order, for the line under an answer.
    static func sources(_ text: String) -> [Source] {
        let pattern = #"\[([0-9]{1,3})\]\((?:<([^>\s]+)>|([^)\s]+))\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [Int: Source] = [:]
        let string = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let raw = match.range(at: 2).location != NSNotFound ? string.substring(with: match.range(at: 2)) : string.substring(with: match.range(at: 3))
            guard let number = Int(string.substring(with: match.range(at: 1))), found[number] == nil,
                  let url = URL(string: raw), isCitation(String(number), url), let host = url.host?.lowercased() else { continue }
            found[number] = Source(number: number, url: url, domain: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        return found.keys.sorted().compactMap { found[$0] }
    }
}

/// A link a model wrote to a file on this Mac: absolute, under ~, or relative to the agent's project,
/// possibly ending in :line or #Lline, which no app can open as a web address.
enum LocalLink {
    static func fileURL(_ url: URL, base: String?) -> URL? {
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return nil }
        var path = url.scheme == nil ? (url.relativeString.removingPercentEncoding ?? url.relativeString) : url.path
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let line = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { path.removeSubrange(line) }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
            guard let base else { return nil }
            path = (base as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

/// Visible source domains replace hover tooltips, which SwiftUI text cannot
/// attach to a single link; hovering the line still lists every full address.
struct SourcesLine: View {
    @Environment(\.boltbarTheme) private var theme
    let sources: [InlineMarkdown.Source]
    var body: some View {
        var line = AttributedString("SOURCES")
        line.swiftUI.font = .system(size: 9, weight: .semibold, design: .monospaced)
        line.swiftUI.foregroundColor = theme.text.opacity(0.55); line.swiftUI.tracking = 1
        // Sources on one site share its domain label: "1 2 swift.org".
        var domains: [String] = []
        for source in sources where !domains.contains(source.domain) { domains.append(source.domain) }
        for domain in domains {
            let group = sources.filter { $0.domain == domain }
            line += AttributedString("   ")
            for source in group {
                var link = AttributeContainer(); link.link = source.url
                line += InlineMarkdown.chip(String(source.number), accent: theme.accent, attributes: link) + AttributedString(" ")
            }
            var label = AttributeContainer(); label.link = group[0].url
            var name = AttributedString(domain, attributes: label)
            name.swiftUI.font = .system(size: 11, design: .monospaced)
            line += name
        }
        return Text(line).lineSpacing(5).tint(theme.accent).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(sources.map { "\($0.number)  \($0.url.absoluteString)" }.joined(separator: "\n"))
    }
}

private struct MarkdownLine: View {
    @Environment(\.boltbarTheme) private var theme
    let line: String
    func inline(_ text: String) -> AttributedString { InlineMarkdown.render(text, accent: theme.accent) }
    var body: some View {
        Group {
            if line.isEmpty { Color.clear.frame(height: 5) }
            else if let marker = line.range(of: "^#{1,6} ", options: .regularExpression) {
                Text(inline(String(line[marker.upperBound...]))).font(.system(size: max(15, 23 - Double(line.distance(from: line.startIndex, to: marker.upperBound))), weight: .semibold)).padding(.top, 4)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                HStack(alignment: .top, spacing: 8) { Text("•").foregroundStyle(.secondary); Text(inline(String(line.dropFirst(2)))).fixedSize(horizontal: false, vertical: true) }.padding(.leading, 4)
            } else if line.hasPrefix("> ") {
                HStack(spacing: 8) { Rectangle().fill(.gray.opacity(0.5)).frame(width: 2); Text(inline(String(line.dropFirst(2)))).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
            } else { Text(inline(line)).fixedSize(horizontal: false, vertical: true) }
        }.font(.system(size: 14)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
