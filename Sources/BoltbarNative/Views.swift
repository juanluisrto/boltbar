import AppKit
import SwiftUI

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
private struct ThreadHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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

struct MessageRow: View {
    let message: Message
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(message.role == .user ? "YOU" : (message.author ?? "ASSISTANT").uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if message.role == .assistant, !message.text.isEmpty {
                    CopyIconButton(text: message.text, label: "Copy response", visible: hovering)
                }
            }.frame(height: 22)
            if !message.attachments.isEmpty { AttachmentStrip(items: message.attachments) }
            if !message.text.isEmpty { MarkdownText(source: message.text) }
            else if message.pending {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message.activity ?? "Thinking…").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            .contentShape(Rectangle()).onHover { hovering = $0 }
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
    @State private var followsStream = true
    var body: some View {
        VStack(spacing: 10) {
            PanelMoveArea().frame(height: 12)
            if model.showingHistory {
                HistoryPane(model: model, close: { model.closeHistory() })
            } else {
            if !model.messages.isEmpty {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.messages) { MessageRow(message: $0) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { Color.clear.preference(key: ThreadHeightKey.self, value: $0.size.height) })
                            .background(ChatScrollObserver { followsStream = $0 })
                    }.frame(height: model.manualThreadHeight ?? min(330, max(44, model.threadHeight)))
                        .onPreferenceChange(ThreadHeightKey.self) { model.threadHeight = $0 }
                        .onChange(of: model.messages.last?.text) { _ in
                            if followsStream { reader.scrollTo("bottom", anchor: .bottom) }
                        }
                        .onChange(of: model.messages.count) { _ in
                            followsStream = true
                            reader.scrollTo("bottom", anchor: .bottom)
                        }
                }
                Rectangle().fill(theme.border).frame(height: 1)
            }
            if !model.attachments.isEmpty {
                AttachmentStrip(items: model.attachments) { id in model.attachments.removeAll { $0.id == id } }
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text("Ask anything…").font(.system(size: 15, design: .monospaced)).foregroundStyle(.gray).padding(.top, 2).allowsHitTesting(false) }
                GrowingEditor(model: model).onAppear { DispatchQueue.main.async { model.focusComposer?() } }
            }.frame(height: model.inputHeight)
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.error).fixedSize(horizontal: false, vertical: true).padding(8).background(theme.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 0)
                    if !model.messages.isEmpty { Button("Retry") { model.retry() }.font(.system(size: 12, design: .monospaced)).buttonStyle(.borderless) }
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
            }
            HStack(spacing: 9) {
                Button { model.pickFiles() } label: { Image(systemName: "plus").font(.system(size: 16, weight: .medium, design: .monospaced)).frame(width: 30, height: 30).background(theme.surface, in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Attach files")
                Button { model.selectingModel = false; model.showingModelPicker.toggle() } label: {
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
                Button { model.showingModelPicker = false; model.showHistory() } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("Previous chats (→ when the message is empty)").accessibilityLabel("Previous chats")
                Button { model.webSearch.toggle() } label: {
                    Image(systemName: "globe").font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(model.webSearchActive ? accent : .secondary)
                        .frame(width: 30, height: 30)
                        .background(model.webSearchActive ? accent.opacity(0.12) : .clear, in: Circle())
                }.buttonStyle(.plain).disabled(!model.canSearchWeb || model.streaming)
                    .accessibilityLabel("Search the web")
                    .accessibilityValue(model.webSearchActive ? "On" : "Off")
                    .help(model.canSearchWeb ? (model.webSearch ? "Web access on · searches when needed" : "Allow web search · remembers your choice") : "Web search with Codex requires an OpenAI API key")
                PanelMoveArea().frame(maxWidth: .infinity).frame(height: 31)
                Button { if model.streaming { model.stop() } else { model.send() } } label: {
                    Image(systemName: model.streaming ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .frame(width: 31, height: 31).background(accent, in: Circle()).foregroundStyle(theme.onAccent)
                }.buttonStyle(.plain).accessibilityLabel(model.streaming ? "Stop" : "Send")
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
        return AttributedString(result)
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

private struct MarkdownLine: View {
    let line: String
    func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
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
