import AppKit
import Foundation

/// Attachments travel through stdin, never shell arguments or temporary files.
enum CLIInput {
    static let instructions = "You are a chat assistant. Answer the user's latest message directly. The input contains the conversation so far, with role labels. Do not use tools, inspect local files, or execute commands."
    static func blocks(_ request: ChatRequest, codex: Bool) throws -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        func text(_ value: String) -> [String: Any] {
            codex ? ["type": "text", "text": value, "text_elements": []] : ["type": "text", "text": value]
        }
        for message in request.messages where !message.text.isEmpty || !message.attachments.isEmpty {
            blocks.append(text("\(message.role.rawValue): \(message.text)"))
            for file in message.attachments {
                if file.isImage {
                    let image = try imagePayload(file)
                    blocks.append(text("Attached image: \(file.name)"))
                    if codex { blocks.append(["type": "image", "url": "data:\(image.mime);base64,\(image.data.base64EncodedString())"]) }
                    else { blocks.append(["type": "image", "source": ["type": "base64", "media_type": image.mime, "data": image.data.base64EncodedString()]]) }
                } else if let contents = file.text {
                    blocks.append(text("Attached document \(file.name):\n\(contents)\n"))
                } else { throw AppError("PDF attachments require API mode. Images and text documents work in CLI mode.") }
            }
        }
        return blocks
    }
    static func imagePayload(_ file: Attachment) throws -> (mime: String, data: Data) {
        if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(file.mime) { return (file.mime, file.data) }
        guard let image = NSImage(data: file.data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError("Could not decode the attached image. Try PNG or JPEG.")
        }
        return ("image/png", png)
    }
}

/// Track partial output per message so completed snapshots don't duplicate it.
struct ClaudeChatStream {
    private var streamed = false
    private var emitted = false
    private(set) var completed = false
    mutating func consume(_ event: [String: Any]) throws -> [String] {
        let type = event["type"] as? String
        if type == "stream_event", let inner = event["event"] as? [String: Any], inner["type"] as? String == "message_start" { streamed = false }
        if let text = Providers.textDelta(event), !text.isEmpty { streamed = true; emitted = true; return [text] }
        if type == "assistant", !streamed, let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }; emitted = emitted || !texts.isEmpty; return texts
        }
        if type == "result" {
            guard event["is_error"] as? Bool != true, event["subtype"] as? String == "success" else {
                throw AppError("The Claude CLI could not complete this request. Check its login and model access.")
            }
            completed = true
            if !emitted, let result = event["result"] as? String, !result.isEmpty { emitted = true; return [result] }
            guard emitted else { throw AppError("The Claude CLI returned no text.") }
        }
        return []
    }
}

struct CodexChatStream {
    private var streamedItems: Set<String> = []
    private var emitted = false
    private(set) var completed = false
    mutating func consume(_ event: [String: Any]) throws -> [String] {
        let method = event["method"] as? String
        let params = event["params"] as? [String: Any] ?? [:]
        if method == "item/agentMessage/delta", let text = params["delta"] as? String, !text.isEmpty {
            streamedItems.insert(params["itemId"] as? String ?? ""); emitted = true; return [text]
        }
        if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
           !streamedItems.contains(item["id"] as? String ?? ""), let text = item["text"] as? String, !text.isEmpty {
            emitted = true; return [text]
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            guard turn["status"] as? String == "completed" else {
                throw AppError("The Codex CLI did not complete this response. Check its login and model access, then retry.")
            }
            guard emitted else { throw AppError("The Codex CLI returned no text.") }
            completed = true
        }
        return []
    }
}

enum CodexChat {
    static let arguments = ["app-server", "--listen", "stdio://", "--disable", "shell_tool", "--disable", "apps",
                            "--disable", "shell_snapshot", "-c", "web_search=\"disabled\"", "-c", "mcp_servers={}"]
    static func stream(_ request: ChatRequest, delta: @escaping (String) async -> Void) async throws {
        let input = try CLIInput.blocks(request, codex: true)
        let child = try LineProcess(program: CLI.program(.openai), args: arguments, keepInputOpen: true)
        defer { child.cancel() }
        try await withTaskCancellationHandler {
            try await child.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "boltbar", "title": "Boltbar", "version": "0.2.0"]]])
            var parser = CodexChatStream()
            for try await line in child.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let id = event["id"], event["method"] != nil {
                    // This chat-only client never grants tool/permission requests.
                    try await child.send(["id": id, "error": ["code": -32601, "message": "Tools are unavailable in Boltbar chat."]]); continue
                }
                if event["error"] != nil {
                    throw AppError("Codex CLI rejected the request. Update Codex and check its login and selected model.")
                }
                switch event["id"] as? Int {
                case 1:
                    try await child.send(["method": "initialized", "params": [:]])
                    try await child.send(["id": 2, "method": "thread/start", "params": [
                        "model": request.model, "cwd": NSTemporaryDirectory(), "ephemeral": true,
                        "approvalPolicy": "never", "sandbox": "read-only", "baseInstructions": CLIInput.instructions]])
                case 2:
                    guard let result = event["result"] as? [String: Any], let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        throw AppError("Codex CLI returned an invalid thread. Update Codex and retry.")
                    }
                    try await child.send(["id": 3, "method": "turn/start", "params": ["threadId": id, "input": input, "effort": request.effort.rawValue]])
                default: break
                }
                for text in try parser.consume(event) { await delta(text) }
                if parser.completed { return }
            }
            throw AppError("The Codex CLI connection ended before the response completed.")
        } onCancel: { child.cancel() }
    }
}
