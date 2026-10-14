import AppKit
import SwiftUI

private let accent = Color(red: 0.98, green: 0.76, blue: 0.34)
private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
private struct ThreadHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AttachmentTile: View {
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
                    Image(systemName: attachment.isPDF ? "doc.richtext" : "doc.text").font(.system(size: 22)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(10).frame(width: 160, height: 44)
            }
        }
        .background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20).background(Color(white: 0.15), in: Circle()) }
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
                    .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if message.role == .assistant, !message.text.isEmpty {
                    CopyIconButton(text: message.text, label: "Copy response", visible: hovering)
                }
            }.frame(height: 22)
            if !message.attachments.isEmpty { AttachmentStrip(items: message.attachments) }
            if !message.text.isEmpty { MarkdownText(source: message.text) }
            else if message.pending {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message.activity ?? "Thinking…").font(.system(size: 13)).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

/// Keep the hit target and layout stable while revealing the action on hover
/// or keyboard focus. Copy the original Markdown, including links and fences.
struct CopyIconButton: View {
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? accent : .secondary)
                .frame(width: 24, height: 22)
                .background(.white.opacity(hovering || focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
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
    @ObservedObject var model: ChatModel
    @State private var showModels = false
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
                    }.frame(height: model.manualThreadHeight ?? min(330, max(44, model.threadHeight)))
                        .onPreferenceChange(ThreadHeightKey.self) { model.threadHeight = $0 }
                        .onChange(of: model.messages.last?.text) { _ in reader.scrollTo("bottom", anchor: .bottom) }
                        .onChange(of: model.messages.count) { _ in reader.scrollTo("bottom", anchor: .bottom) }
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            }
            if !model.attachments.isEmpty {
                AttachmentStrip(items: model.attachments) { id in model.attachments.removeAll { $0.id == id } }
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text("Ask anything…").font(.system(size: 15)).foregroundStyle(.gray).padding(.top, 2).allowsHitTesting(false) }
                GrowingEditor(model: model).onAppear { DispatchQueue.main.async { model.focusComposer?() } }
            }.frame(height: model.inputHeight)
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !model.messages.isEmpty { Button("Retry") { model.retry() }.font(.system(size: 12)).buttonStyle(.borderless) }
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
            }
            HStack(spacing: 9) {
                Button { model.pickFiles() } label: { Image(systemName: "plus").font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30).background(.white.opacity(0.07), in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Attach files")
                Button { showModels.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(modelTitle(model.model)).lineLimit(1)
                        EffortGauge(effort: model.preferences.effort).frame(width: 18, height: 16).accessibilityHidden(true)
                    }
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).frame(height: 29).background(.white.opacity(0.07), in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("Effort and model")
                    .accessibilityValue("\(modelTitle(model.model)), \(model.preferences.effort.title) effort")
                    .help("\(model.preferences.effort.title) effort")
                    .popover(isPresented: $showModels, arrowEdge: .top) { ModelPopover(model: model, close: { showModels = false }) }
                Button { showModels = false; model.showHistory() } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("Previous chats (→ when the message is empty)").accessibilityLabel("Previous chats")
                Button { model.webSearch.toggle() } label: {
                    Image(systemName: "globe").font(.system(size: 15))
                        .foregroundStyle(model.webSearchActive ? accent : .secondary)
                        .frame(width: 30, height: 30)
                        .background(model.webSearchActive ? accent.opacity(0.12) : .clear, in: Circle())
                }.buttonStyle(.plain).disabled(!model.canSearchWeb || model.streaming)
                    .accessibilityLabel("Search the web")
                    .accessibilityValue(model.webSearchActive ? "On" : "Off")
                    .help(model.canSearchWeb ? (model.webSearch ? "Web search on · click to turn off" : "Search the web · remembers your choice") : "Web search requires OpenAI with an API key")
                PanelMoveArea().frame(maxWidth: .infinity).frame(height: 31)
                Button { if model.streaming { model.stop() } else { model.send() } } label: {
                    Image(systemName: model.streaming ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .semibold))
                        .frame(width: 31, height: 31).background(accent, in: Circle()).foregroundStyle(.black)
                }.buttonStyle(.plain).accessibilityLabel(model.streaming ? "Stop" : "Send")
            }
            }
            if let error = model.historyError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 14)
        .frame(width: model.panelWidth).background(Color(red: 0.105, green: 0.105, blue: 0.115))
        .clipShape(RoundedRectangle(cornerRadius: 19)).preferredColorScheme(.dark)
        .overlay(PanelBorders(model: model))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { model.resize?($0) }
    }
}

struct EffortGauge: View {
    let effort: Effort
    private var angle: Double { switch effort { case .low: return -150; case .medium: return -90; case .high: return -30 } }
    var body: some View {
        ZStack {
            Path { path in
                path.addArc(center: CGPoint(x: 9, y: 12), radius: 7.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            }.stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
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
    @ObservedObject var model: ChatModel
    let close: () -> Void
    var effort: Binding<Double> { Binding(get: { Double(Effort.allCases.firstIndex(of: model.preferences.effort) ?? 0) }, set: { model.preferences.effort = Effort.allCases[min(2, max(0, Int($0.rounded())))] }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Thinking effort"); Spacer(); Text(model.preferences.effort.title).frame(width: 52, alignment: .trailing).foregroundStyle(.secondary) }.font(.system(size: 12, weight: .medium))
            Slider(value: effort, in: 0...2, step: 1).tint(accent).accessibilityLabel("Thinking effort")
            HStack { Text("Low"); Spacer(); Text("Medium"); Spacer(); Text("High") }.font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Provider.allCases) { provider in
                        Text(provider.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(model.catalogs[provider]?.models ?? provider.defaults, id: \.self) { id in
                            Button {
                                model.preferences.provider = provider; model.preferences.models[provider.rawValue] = id; close()
                            } label: {
                                HStack { Text(modelTitle(id)).lineLimit(1); Spacer(); if model.provider == provider && model.model == id { Image(systemName: "checkmark").foregroundStyle(accent) } }
                                    .font(.system(size: 12)).padding(.vertical, 7).padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(maxHeight: 280)
            Button("Provider settings…") { close(); model.openSettings?() }.font(.system(size: 11)).buttonStyle(.borderless)
        }.padding(16).frame(width: 280).background(Color(white: 0.12)).preferredColorScheme(.dark)
    }
}

struct MarkdownText: View {
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
    static func highlighted(_ source: String) -> AttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [.foregroundColor: NSColor(white: 0.86, alpha: 1), .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let rules: [(String, NSColor)] = [
            (#"\b(let|var|func|fn|struct|class|enum|import|use|return|if|else|for|while|async|await|def|const|function|true|false|nil|null|public|private|static|throw|try)\b"#, .systemPurple),
            (#"\b[0-9]+(?:\.[0-9]+)?\b"#, .systemOrange),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, .systemGreen),
            (#"(?m)//[^\n]*|^[ \t]*#[^\n]*"#, .systemGray),
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
                        HStack { Text(block.language.isEmpty ? "Code" : block.language).foregroundStyle(.secondary); Spacer(); CopyIconButton(text: block.text, label: "Copy code") }.font(.system(size: 10))
                        ScrollView(.horizontal) { Text(Self.highlighted(block.text)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                    }.padding(10).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
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
