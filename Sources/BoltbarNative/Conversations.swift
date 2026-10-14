import Foundation

struct ConversationSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
}

struct Conversation: Codable {
    let summary: ConversationSummary
    let messages: [Message]
    let provider: Provider
    let model: String
    let effort: Effort
    let transport: Transport

    static func title(for messages: [Message]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "New conversation" }
        let text = first.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String((text.isEmpty ? first.attachments.first?.name ?? "Attachments" : text).prefix(90))
    }
}

/// Payloads are read only when selected; the list keeps a small metadata index.
/// A serial queue preserves save/load ordering without encoding images on the UI thread.
final class ConversationStore: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.boltbar.history", qos: .utility)
    private var index: [ConversationSummary]
    var summaries: [ConversationSummary] { queue.sync { index } }

    static func local() throws -> ConversationStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try ConversationStore(directory: support.appendingPathComponent("Boltbar/Conversations", isDirectory: true))
    }
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: url.path) {
            index = try JSONDecoder().decode([ConversationSummary].self, from: Data(contentsOf: url))
        } else { index = [] }
    }
    func save(_ conversation: Conversation, completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                try self.write(conversation, to: self.url(conversation.summary.id))
                var next = self.index.filter { $0.id != conversation.summary.id }
                next.append(conversation.summary); next.sort { $0.updatedAt > $1.updatedAt }
                try self.write(next, to: self.directory.appendingPathComponent("index.json"))
                self.index = next
                completion(nil)
            } catch { completion(error) }
        }
    }
    func load(_ id: UUID) async throws -> Conversation {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: self.url(id)))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func flush() { queue.sync {} }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ConversationDate {
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_GB"); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.shortMonthSymbols = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]
        if calendar.isDate(date, inSameDayAs: now) { format.dateFormat = "HH:mm" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        else { format.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy" }
        return format.string(from: date)
    }
}
