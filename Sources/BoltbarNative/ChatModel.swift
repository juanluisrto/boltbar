import AppKit
import SwiftUI

@MainActor final class ChatModel: ObservableObject {
    typealias Streamer = (ChatRequest, @escaping (String) async -> Void) async throws -> Void
    @Published var preferences: Preferences { didSet { persist() } }
    @Published var catalogs: [Provider: Catalog] = [:]
    @Published var draft = ""
    @Published var attachments: [Attachment] = []
    @Published var messages: [Message] = []
    @Published var inputHeight: CGFloat = 26
    @Published var manualInputHeight: CGFloat = 26
    @Published var panelWidth: CGFloat = 700
    @Published var threadHeight: CGFloat = 44
    @Published var manualThreadHeight: CGFloat?
    @Published var streaming = false
    @Published var error: String?
    @Published var refreshing = false
    var resize: ((NSSize) -> Void)?
    var openSettings: (() -> Void)?
    var newConversation: (() -> Void)?
    var resizeOrigin: NSPoint?
    var updateShortcut: ((UInt32, UInt32, String) -> Bool)?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var lastRequest: ChatRequest?
    private let defaults: UserDefaults
    private let streamer: Streamer

    init(defaults: UserDefaults = .standard, streamer: @escaping Streamer = Providers.stream) {
        self.defaults = defaults
        self.streamer = streamer
        preferences = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        for provider in Provider.allCases {
            if !provider.accepts(preferences.model(provider)) { preferences.models[provider.rawValue] = provider.defaults[0] }
            catalogs[provider] = Catalog(models: provider.defaults, detail: "Checking login…", ready: false)
        }
    }
    var provider: Provider { preferences.provider }
    var model: String { preferences.model(provider) }
    func persist() { if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences") } }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        let transports = preferences.transports
        await withTaskGroup(of: (Provider, Catalog).self) { group in
            for provider in Provider.allCases {
                group.addTask { (provider, await Providers.catalog(provider, transport: transports[provider.rawValue] ?? .automatic)) }
            }
            for await (provider, catalog) in group {
                catalogs[provider] = catalog
                if catalog.ready, !catalog.models.contains(preferences.model(provider)), let first = catalog.models.first {
                    preferences.models[provider.rawValue] = first
                }
            }
        }
        refreshing = false
    }
    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        draft = ""; attachments = []; messages = []; streaming = false; error = nil
        inputHeight = 26; manualInputHeight = 26; lastRequest = nil
        manualThreadHeight = nil; threadHeight = 44
        resizeOrigin = nil
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; streaming = false
        for index in messages.indices { messages[index].pending = false }
    }
    func send() {
        guard !streaming else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // The sent message owns its attachments. Clearing the composer cannot
        // remove the thumbnail or the image from later conversation requests.
        messages.append(Message(role: .user, text: text, attachments: attachments))
        draft = ""; attachments = []; inputHeight = 26; manualInputHeight = 26
        begin(ChatRequest(provider: provider, model: model, effort: preferences.effort,
            transport: preferences.transport(provider), messages: messages))
    }
    func retry() {
        guard !streaming, let previous = lastRequest else { return }
        messages = previous.messages
        begin(ChatRequest(provider: provider, model: model, effort: preferences.effort,
            transport: preferences.transport(provider), messages: messages))
    }
    private func begin(_ request: ChatRequest) {
        error = nil; streaming = true; generation = UUID(); let current = generation
        lastRequest = request
        let assistant = Message(role: .assistant, text: "", pending: true, author: request.provider.title)
        messages.append(assistant)
        let streamer = self.streamer
        task = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var first: Double?; var count = 0
            do {
                try await streamer(request) { [weak self] text in
                    guard let self, self.generation == current,
                          let index = self.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                    if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                    count += 1; self.messages[index].text += text
                }
                metric(["kind": "stream", "provider": request.provider.rawValue, "model": request.model,
                    "ttft_ms": first ?? -1, "total_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000, "deltas": count])
            } catch {
                if let self, self.generation == current, !Task.isCancelled { self.error = error.localizedDescription }
            }
            if let self, self.generation == current {
                self.streaming = false
                if let index = self.messages.firstIndex(where: { $0.id == assistant.id }) { self.messages[index].pending = false }
            }
        }
    }
    func add(_ items: [Attachment]) {
        guard attachments.count + items.count <= 6 else { error = "Attach up to six files per message."; return }
        attachments.append(contentsOf: items); error = nil
    }
    func addURLs(_ urls: [URL]) {
        do { add(try urls.map(Attachment.init(url:))) } catch { self.error = error.localizedDescription }
    }
    func pickFiles() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        picker.title = "Attach images or documents"
        picker.begin { [weak self] result in
            if result == .OK { Task { @MainActor in self?.addURLs(picker.urls) } }
        }
    }
    func receive(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addURLs(urls); return true
        }
        if pasteboard.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            do { add([try Attachment(name: "Pasted image.png", mime: "image/png", data: png)]) }
            catch { self.error = error.localizedDescription }
            return true
        }
        return false
    }
}
