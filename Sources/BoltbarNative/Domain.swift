import AppKit
import UniformTypeIdentifiers
import Security
import LocalAuthentication

enum Provider: String, Codable, CaseIterable, Identifiable {
    case openai, anthropic
    // Read legacy chats/preferences without keeping the removed integration.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "cursor" { self = .openai; return }
        guard let provider = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider")
        }
        self = provider
    }
    var id: String { rawValue }
    var title: String { ["openai": "OpenAI", "anthropic": "Anthropic"][rawValue]! }
    var defaults: [String] {
        switch self {
        case .openai: return FeaturedModels.fallback
        case .anthropic: return ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-haiku-5-5"]
        }
    }
    var loginCommand: String {
        switch self { case .openai: return "codex login"; case .anthropic: return "claude auth login" }
    }
    func accepts(_ model: String) -> Bool {
        let id = model.lowercased()
        if ["audio", "realtime", "embed", "transcrib", "tts", "image", "search", "moderation", "codex", "deep-research", "-pro", "instruct"].contains(where: id.contains) { return false }
        switch self {
        case .openai: return id.range(of: "^gpt-[5-9][0-9]*([.-]|$)|^gpt-4[.]1([.-]|$)|^gpt-4o(-|$)|^o[34](-|$)", options: .regularExpression) != nil
        case .anthropic: return id.range(of: "^claude-(sonnet|opus|haiku|fable)-(4-[6-9]|[5-9])(-|$)", options: .regularExpression) != nil
        }
    }
}

enum Effort: String, Codable, CaseIterable { case low, medium, high
    var title: String { rawValue.capitalized }
}
enum Transport: String, Codable, CaseIterable { case automatic, api, cli
    var title: String { switch self { case .automatic: return "Automatic"; case .api: return "API key"; case .cli: return "CLI login" } }
}
struct Preferences: Codable {
    var provider: Provider = .openai
    var models: [String: String] = [:]
    var effort: Effort = .low
    var transports: [String: Transport] = [:]
    var shortcutKey: UInt32 = 49
    var shortcutModifiers: UInt32 = 2048 // Carbon optionKey
    var shortcutLabel = "⌥ Space"
    func model(_ provider: Provider) -> String { models[provider.rawValue] ?? (provider == .openai ? "gpt-6.1-sol" : provider.defaults[0]) }
    func transport(_ provider: Provider) -> Transport { transports[provider.rawValue] ?? .automatic }
}

struct Attachment: Identifiable, Codable {
    let id: UUID
    let name: String
    let mime: String
    let data: Data
    var isImage: Bool { mime.hasPrefix("image/") }
    var isPDF: Bool { mime == "application/pdf" }
    var image: NSImage? { isImage ? NSImage(data: data) : nil }
    var text: String? { !isImage && !isPDF ? String(data: data, encoding: .utf8) : nil }
    static let maxBytes = 10 * 1024 * 1024

    init(name: String, mime: String, data: Data, id: UUID = UUID()) throws {
        guard data.count <= Self.maxBytes else { throw AppError("Each attachment must be 10 MB or smaller.") }
        guard !data.isEmpty else { throw AppError("The attachment is empty.") }
        guard mime.hasPrefix("image/") || mime == "application/pdf" || String(data: data, encoding: .utf8) != nil else {
            throw AppError("Use an image, PDF, or UTF-8 text document.")
        }
        self.id = id; self.name = name; self.mime = mime; self.data = data
    }
    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= Self.maxBytes else { throw AppError("Choose a file of at most 10 MB.") }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        try self.init(name: url.lastPathComponent, mime: type?.preferredMIMEType ?? "text/plain", data: data)
    }
}

struct Message: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    var text: String
    var attachments: [Attachment] = []
    var pending = false
    var author: String? = nil
    var activity: String? = nil
    /// Optional so chats saved before this field existed still decode.
    var interrupted: Bool? = nil
    /// What the agent did during this reply, in order.
    var steps: [AgentStep]? = nil
    /// Everything a message row shows; attachments compare by identity, not by their bytes.
    func sameContent(as other: Message) -> Bool {
        id == other.id && role == other.role && text == other.text && pending == other.pending && author == other.author
            && activity == other.activity && interrupted == other.interrupted && steps == other.steps
            && attachments.map(\.id) == other.attachments.map(\.id)
    }
}
struct ChatRequest {
    let provider: Provider
    let model: String
    let effort: Effort
    let transport: Transport
    let messages: [Message]
    var webSearch = false
    /// Set in agent mode: the CLI acts in a project folder and asks Boltbar before acting.
    var agent: AgentTurn? = nil
}
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Keychain {
    static let service = "com.boltbar.keys"
    // File-based login keychains can ignore LAContext.interactionNotAllowed.
    // Serialize the legacy process-wide UI flag, restoring it after each read.
    private static let interactionLock = NSLock()
    static func read(_ provider: Provider, allowInteraction: Bool = false) throws -> String? {
        interactionLock.lock(); defer { interactionLock.unlock() }
        var previous: DarwinBoolean = false
        let captured = SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess
        if !allowInteraction {
            guard captured, SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw AppError("Could not read Keychain without interaction. Use Settings to allow access.") }
        }
        defer { if captured && !allowInteraction { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        if code == errSecInteractionNotAllowed || code == errSecAuthFailed {
            throw AppError("Approve access to the saved \(provider.title) key in Settings.")
        }
        guard code == errSecSuccess else { throw AppError("Keychain read failed (\(code)).") }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func save(_ key: String, for provider: Provider) throws {
        interactionLock.lock(); defer { interactionLock.unlock() }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError("Enter an API key to save it.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AppError("Keychain save failed (\(status)).") }
    }
    static func key(_ provider: Provider) throws -> String? {
        // A credential explicitly supplied by the launching environment takes
        // precedence. Finder launches use the saved Keychain item.
        if let key = ProcessInfo.processInfo.environment[provider.rawValue.uppercased() + "_API_KEY"], !key.isEmpty { return key }
        if let key = try read(provider), !key.isEmpty { return key }
        return nil
    }
}

func modelTitle(_ id: String) -> String {
    if let parts = FeaturedModels.parts(id) { return "GPT-\(parts.version.map(String.init).joined(separator: ".")) \(parts.family.capitalized)" }
    let known = ["gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-astra": "GPT-6 Astra", "gpt-6-luna": "GPT-6 Luna", "gpt-6-sol": "GPT-6 Sol",
        "claude-sonnet-5-5": "Claude Sonnet 5.5", "claude-opus-5-5": "Claude Opus 5.5", "claude-fable-5-1": "Claude Fable 5.1", "claude-haiku-5-5": "Claude Haiku 5.5", "auto": "Auto"]
    return known[id] ?? id
}

func metric(_ values: [String: Any]) {
    guard ProcessInfo.processInfo.environment["BOLTBAR_QA_METRICS"] != nil,
          let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) else { return }
    print(line); fflush(stdout)
}
