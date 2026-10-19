import Foundation

enum StreamUpdate {
    case text(String)
    case replaceText(String)
    case activity(String)
}

/// A citation never touches the next word, while closing punctuation and
/// emphasis markers stay attached to the text they belong to.
enum CitationSpacing {
    static func separates(_ next: Character) -> Bool {
        !next.isWhitespace && !".,;:!?)]}»”’…*_~`".contains(next)
    }
}

/// Convert provider citation annotations into portable, clickable Markdown.
/// Offsets are Unicode scalar positions, not Swift's grapheme-cluster count.
enum WebCitations {
    static func markdown(_ text: String, annotations: [[String: Any]]) -> String {
        let scalars = Array(text.unicodeScalars)
        var links: [String] = [], edits: [Int: (start: Int, labels: [String])] = [:]
        var fallback: [String] = []
        for annotation in annotations {
            guard annotation["type"] as? String == "url_citation",
                  let rawURL = annotation["url"] as? String, let url = URL(string: rawURL),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { continue }
            let address = url.absoluteString.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C")
            if !links.contains(address) { links.append(address) }
            let label = "[\(links.firstIndex(of: address)! + 1)](<\(address)>)"
            guard let start = annotation["start_index"] as? Int, let end = annotation["end_index"] as? Int,
                  start >= 0, end >= start, end <= scalars.count else {
                if !fallback.contains(label) { fallback.append(label) }; continue
            }
            let span = String(String.UnicodeScalarView(scalars[start..<end]))
            // Some annotations cover a citation marker, others cover the claim.
            // Only replace markers; preserve the actual words of the answer.
            let marker = span.hasPrefix("cite") && span.hasSuffix("")
            let insertionStart = marker ? start : end
            var edit = edits[end] ?? (insertionStart, [])
            edit.start = min(edit.start, insertionStart)
            if !edit.labels.contains(label) { edit.labels.append(label) }
            edits[end] = edit
        }
        var result = scalars
        var boundary = scalars.count
        for end in edits.keys.sorted(by: >) {
            let edit = edits[end]!
            guard end <= boundary else {
                fallback.append(contentsOf: edit.labels.filter { !fallback.contains($0) }); continue
            }
            let prefix = edit.start > 0 && !Character(scalars[edit.start - 1]).isWhitespace ? " " : ""
            let suffix = end < scalars.count && CitationSpacing.separates(Character(scalars[end])) ? " " : ""
            result.replaceSubrange(edit.start..<end, with: (prefix + edit.labels.joined(separator: " ") + suffix).unicodeScalars)
            boundary = edit.start
        }
        var rendered = String(String.UnicodeScalarView(result))
        if !fallback.isEmpty { rendered += "\n\nSources: " + fallback.joined(separator: " ") }
        return rendered
    }
}

/// Keep raw text separate from rendered citations so later annotation offsets
/// stay correct while text is streaming, including multiple output items.
struct OpenAITextStream {
    struct Part {
        var text = ""
        var annotations: [Int: [String: Any]] = [:]
        var rendered: String { WebCitations.markdown(text, annotations: annotations.keys.sorted().compactMap { annotations[$0] }) }
    }
    struct Position: Hashable, Comparable {
        let output: Int, content: Int
        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.output, lhs.content) < (rhs.output, rhs.content) }
    }
    private var parts: [Position: Part] = [:]
    private var rendered: String { parts.keys.sorted().compactMap { parts[$0]?.rendered }.joined(separator: "\n\n") }

    mutating func consume(_ event: [String: Any]) -> [StreamUpdate] {
        let position = Position(output: event["output_index"] as? Int ?? 0, content: event["content_index"] as? Int ?? 0)
        switch event["type"] as? String {
        case "response.output_text.delta":
            guard let text = event["delta"] as? String else { return [] }
            parts[position, default: Part()].text += text
            return [.text(text)]
        case "response.output_text.annotation.added":
            guard let annotation = event["annotation"] as? [String: Any] else { return [] }
            let index = event["annotation_index"] as? Int ?? parts[position, default: Part()].annotations.count
            parts[position, default: Part()].annotations[index] = annotation
            return [.replaceText(rendered)]
        case "response.output_text.done":
            if let text = event["text"] as? String { parts[position, default: Part()].text = text }
            return [.replaceText(rendered)]
        case "response.web_search_call.in_progress", "response.web_search_call.searching":
            return [.activity("Searching the web…")]
        case "response.web_search_call.completed":
            return [.activity("Writing answer…")]
        case "response.completed":
            guard let response = event["response"] as? [String: Any], let output = response["output"] as? [[String: Any]] else { return [] }
            let texts = output.flatMap { item -> [String] in
                (item["content"] as? [[String: Any]] ?? []).compactMap { part in
                    guard part["type"] as? String == "output_text", let text = part["text"] as? String else { return nil }
                    return WebCitations.markdown(text, annotations: part["annotations"] as? [[String: Any]] ?? [])
                }
            }
            return texts.isEmpty ? [] : [.replaceText(texts.joined(separator: "\n\n"))]
        default: return []
        }
    }
}

/// Claude emits web citations alongside text deltas, without text offsets.
/// Hold each block's citations until the block ends, so they follow the cited
/// claim whatever the event order, and keep trailing whitespace back so a
/// citation lands before a line break instead of at the start of the next line.
struct AnthropicTextStream {
    private var urls: [String] = []
    private var cited: [String] = []
    private var held = ""
    private var emitted = false
    private var afterCitation = false
    mutating func consume(_ event: [String: Any]) throws -> [StreamUpdate] {
        switch event["type"] as? String {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { return [] }
            if block["type"] as? String == "server_tool_use", block["name"] as? String == "web_search" {
                return [.activity("Searching the web…")]
            }
            if block["type"] as? String == "web_search_tool_result" {
                if let content = block["content"] as? [String: Any], content["type"] as? String == "web_search_tool_result_error" {
                    throw AppError("Claude web search failed. Check web search access in the Claude Console, then retry.")
                }
                return [.activity("Writing answer…")]
            }
            return []
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            if let text = delta["text"] as? String { return self.text(text) }
            if delta["type"] as? String == "citations_delta", let citation = delta["citation"] as? [String: Any],
               citation["type"] as? String == "web_search_result_location", let raw = citation["url"] as? String,
               let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                let address = url.absoluteString.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C")
                if !urls.contains(address) { urls.append(address) }
                let label = "[\(urls.firstIndex(of: address)! + 1)](<\(address)>)"
                if !cited.contains(label) { cited.append(label) }
            }
            return []
        case "content_block_stop":
            guard !cited.isEmpty else { return [] }
            defer { cited = []; held = "" }
            let prefix = emitted ? " " : ""
            afterCitation = held.isEmpty; emitted = true
            return [.text(prefix + cited.joined(separator: " ") + held)]
        default: return []
        }
    }
    private mutating func text(_ delta: String) -> [StreamUpdate] {
        let value = held + delta
        guard let last = value.lastIndex(where: { !$0.isWhitespace }) else { held = value; return [] }
        held = String(value[value.index(after: last)...])
        var visible = String(value[...last])
        if afterCitation, let first = visible.first, CitationSpacing.separates(first) { visible = " " + visible }
        afterCitation = false; emitted = true
        return [.text(visible)]
    }
}
