import Foundation

struct Catalog {
    var models: [String]
    var detail: String
    var ready: Bool
    var live = false
}

/// SSE framing preserves blank lines and partial UTF-8 sequences. Foundation's
/// AsyncLineSequence omits empty lines, which are significant SSE delimiters.
struct EventFrames {
    var data: [String] = []
    private var line = Data()
    mutating func consume(byte: UInt8) throws -> String? {
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw AppError("The provider sent invalid UTF-8.") }
        line.removeAll(keepingCapacity: true)
        return consume(text)
    }
    mutating func consume(_ line: String) -> String? {
        if line.isEmpty {
            defer { data.removeAll(keepingCapacity: true) }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            data.append(String(value.first == " " ? value.dropFirst() : value))
        }
        return nil
    }
}

enum Providers {
    static func body(_ request: ChatRequest) -> [String: Any] {
        let messages: [[String: Any]] = request.messages.map { message in
            var parts: [[String: Any]] = []
            let textType = request.provider == .openai ? (message.role == .user ? "input_text" : "output_text") : "text"
            if !message.text.isEmpty { parts.append(["type": textType, "text": message.text]) }
            for file in message.attachments {
                if file.isImage {
                    if request.provider == .openai {
                        parts.append(["type": "input_image", "image_url": "data:\(file.mime);base64,\(file.data.base64EncodedString())"])
                    } else {
                        parts.append(["type": "image", "source": ["type": "base64", "media_type": file.mime, "data": file.data.base64EncodedString()]])
                    }
                } else if file.isPDF {
                    if request.provider == .openai {
                        parts.append(["type": "input_file", "filename": file.name, "file_data": "data:application/pdf;base64,\(file.data.base64EncodedString())"])
                    } else {
                        parts.append(["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": file.data.base64EncodedString()]])
                    }
                } else if let text = file.text {
                    parts.append(["type": textType, "text": "Attached document: \(file.name)\n\(text)"])
                }
            }
            return ["role": message.role.rawValue, "content": parts]
        }
        if request.provider == .openai {
            var body: [String: Any] = ["model": request.model, "stream": true, "reasoning": ["effort": request.effort.rawValue], "input": messages]
            if request.webSearch {
                body["tools"] = [["type": "web_search"]]
                body["tool_choice"] = "required"
            }
            return body
        }
        return ["model": request.model, "stream": true, "max_tokens": 8192,
            "thinking": ["type": "adaptive"], "output_config": ["effort": request.effort.rawValue], "messages": messages]
    }

    static func stream(_ request: ChatRequest, update: @escaping (StreamUpdate) async -> Void) async throws {
        if request.webSearch && (request.provider != .openai || request.transport == .cli) {
            throw AppError("Web search needs OpenAI with an API key. Select OpenAI and API key or Automatic in Settings.")
        }
        if request.transport == .cli || request.provider == .cursor {
            try await CLI.stream(request) { await update(.text($0)) }; return
        }
        let key = try Keychain.key(request.provider)
        if request.transport == .automatic && key == nil {
            guard !request.webSearch else { throw AppError("Add an OpenAI API key in Settings to search the web.") }
            try await CLI.stream(request) { await update(.text($0)) }
            return
        }
        guard request.provider != .cursor else { throw AppError("Cursor chat uses its official CLI. Run agent login and select CLI login.") }
        guard let key, !key.isEmpty else { throw AppError("Add an API key in Settings or choose an existing CLI login.") }
        let address = request.provider == .openai ? "https://api.openai.com/v1/responses" : "https://api.anthropic.com/v1/messages"
        var http = URLRequest(url: URL(string: address)!)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if request.provider == .openai { http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        else {
            http.setValue(key, forHTTPHeaderField: "x-api-key")
            http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body(request))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        metric(["kind": "headers", "provider": request.provider.rawValue, "status": status])
        guard (200..<300).contains(status) else { throw AppError("\(request.provider.title) returned HTTP \(status). Check the key, model access, and quota in Settings.") }
        var frames = EventFrames(), openAI = OpenAITextStream()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let data = try frames.consume(byte: byte) else { continue }
            guard let json = data.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            let type = event["type"] as? String ?? ""
            if ["error", "response.failed", "response.incomplete"].contains(type) { throw AppError("The provider did not complete the response. You can retry this message.") }
            if request.provider == .openai {
                for item in openAI.consume(event) { await update(item) }
            } else if let text = textDelta(event), !text.isEmpty { await update(.text(text)) }
            if ["response.completed", "message_stop"].contains(type) { return }
        }
        throw AppError("The connection ended before the response completed.")
    }

    static func textDelta(_ event: [String: Any]) -> String? {
        switch event["type"] as? String {
        case "response.output_text.delta": return event["delta"] as? String
        case "content_block_delta": return (event["delta"] as? [String: Any])?["text"] as? String
        case "stream_event": return (event["event"] as? [String: Any]).flatMap(textDelta)
        default: return nil
        }
    }

    static func catalog(_ provider: Provider, transport: Transport) async -> Catalog {
        do {
            if transport != .cli, provider != .cursor, let key = try Keychain.key(provider) {
                let url = provider == .openai ? "https://api.openai.com/v1/models" : "https://api.anthropic.com/v1/models"
                var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 10
                if provider == .openai { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                else { request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let (data, reply) = try await session.data(for: request)
                guard (reply as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("Model catalog unavailable; check API access.") }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rows = json?["data"] as? [[String: Any]] ?? []
                let available = Array(Set(rows.compactMap { $0["id"] as? String }.filter(provider.accepts)))
                let ids = provider == .openai ? FeaturedModels.latest(available) : available.sorted {
                    let left = provider.defaults.firstIndex(of: $0) ?? 999, right = provider.defaults.firstIndex(of: $1) ?? 999
                    return left == right ? $0 < $1 : left < right
                }
                guard !ids.isEmpty else { throw AppError("No supported chat models returned by the provider.") }
                return Catalog(models: ids, detail: provider == .openai ? "API · latest Astra, Sol and Luna · synced live" : "API · live catalog", ready: true, live: true)
            }
            guard transport != .api else { throw AppError("Add an API key in Settings.") }
            let program = try CLI.program(provider)
            let args: [String] = provider == .openai ? ["login", "status"] : provider == .anthropic ? ["auth", "status"] : ["--list-models"]
            let output = try await CLI.capture(program, args: args)
            if provider == .anthropic, let data = output.data(using: .utf8), let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any], status["loggedIn"] as? Bool == false {
                throw AppError("Run \(provider.loginCommand), then refresh.")
            }
            if provider == .cursor {
                let models = output.split(separator: "\n").compactMap { line -> String? in
                    let id = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                    return id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil && provider.accepts(id) ? id : nil
                }
                guard !models.isEmpty else { throw AppError("Run agent login, then refresh.") }
                return Catalog(models: models, detail: "Cursor CLI · live catalog", ready: true)
            }
            return Catalog(models: provider.defaults, detail: "CLI login · fallback catalog", ready: true)
        } catch {
            return Catalog(models: provider.defaults, detail: error.localizedDescription + " Fallback catalog.", ready: false)
        }
    }
}

/// Process IO is drained concurrently. No transcript or credentials are written
/// by Boltbar; official CLIs remain responsible for their own authentication.
final class LineProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data(), stderr = Data()
    private var eof = false, exited = false, finished = false
    private var continuation: AsyncThrowingStream<String, Error>.Continuation!
    private(set) var lines: AsyncThrowingStream<String, Error>!

    init(program: String, args: [String], stdin: Data? = nil) throws {
        process.executableURL = URL(fileURLWithPath: program); process.arguments = args
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment
        lines = AsyncThrowingStream { self.continuation = $0 }
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock(); self.stderr.append(data.prefix(max(0, 8192 - self.stderr.count))); self.lock.unlock()
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.exited = true; self.finishIfReady(); self.lock.unlock()
        }
        do { try process.run() } catch { cancel(); throw error }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let stdin { try? self.input.fileHandleForWriting.write(contentsOf: stdin) }
            try? self.input.fileHandleForWriting.close()
        }
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            if let text = String(data: line, encoding: .utf8) { continuation.yield(text) }
        }
        if data.isEmpty {
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { continuation.yield(line) }
            eof = true; output.fileHandleForReading.readabilityHandler = nil; finishIfReady()
        }
    }
    private func finishIfReady() {
        guard eof, exited, !finished else { return }; finished = true
        if process.terminationStatus == 0 { continuation.finish() }
        else { continuation.finish(throwing: AppError("CLI exited with status \(process.terminationStatus). Check its login and selected model.")) }
    }
    func cancel() {
        if process.isRunning { process.terminate() }
    }
    deinit { output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil; cancel() }
}

enum CLI {
    static func program(_ provider: Provider) throws -> String {
        let names = provider == .openai ? ["codex"] : provider == .anthropic ? ["claude"] : ["agent", "cursor-agent"]
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin"]
        for name in names { for directory in paths {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        } }
        throw AppError("Install the official \(provider.title) CLI, then run \(provider.loginCommand).")
    }
    static func capture(_ program: String, args: [String]) async throws -> String {
        let child = try LineProcess(program: program, args: args)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { var text = ""; for try await line in child.lines { text += line + "\n" }; return text }
            group.addTask { try await Task.sleep(nanoseconds: 12_000_000_000); child.cancel(); throw AppError("CLI status timed out.") }
            defer { group.cancelAll(); child.cancel() }
            return try await group.next()!
        }
    }
    static func stream(_ request: ChatRequest, delta: @escaping (String) async -> Void) async throws {
        let program = try program(request.provider)
        var prompt = "Answer as a chat assistant. Do not use tools or inspect local files.\n\n"
        for message in request.messages {
            prompt += "\(message.role.rawValue): \(message.text)\n"
            for file in message.attachments {
                guard let text = file.text else { throw AppError("Images and PDFs require an API key transport. The CLI transport supports text documents.") }
                prompt += "Attached document \(file.name):\n\(text)\n"
            }
        }
        let args: [String]
        switch request.provider {
        case .openai:
            args = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--disable", "shell_tool", "--disable", "apps", "-c", "model_reasoning_effort=\"\(request.effort.rawValue)\"", "-m", request.model, "-"]
        case .anthropic:
            args = ["-p", "--verbose", "--include-partial-messages", "--output-format", "stream-json", "--model", request.model, "--effort", request.effort.rawValue, "--tools", "", "--", prompt]
        case .cursor:
            args = ["-p", "--output-format", "stream-json", "--stream-partial-output", "--mode", "ask", "--model", request.model, prompt]
        }
        let child = try LineProcess(program: program, args: args, stdin: request.provider == .openai ? Data(prompt.utf8) : nil)
        defer { child.cancel() }
        var partial = false, emitted = false
        for try await line in child.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = event["type"] as? String ?? ""
            if let text = Providers.textDelta(event) { partial = true; emitted = true; await delta(text); continue }
            if type == "result", event["is_error"] as? Bool == true { throw AppError("The CLI could not complete this request. Check its login and model access.") }
            if type == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message", let text = item["text"] as? String {
                emitted = true; await delta(text)
            }
            if !partial, type == "assistant", let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
                for part in content { if let text = part["text"] as? String { emitted = true; await delta(text) } }
            }
        }
        guard emitted else { throw AppError("The CLI returned no text.") }
    }
}
