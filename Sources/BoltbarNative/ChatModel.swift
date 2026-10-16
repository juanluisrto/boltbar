import AppKit
import SwiftUI

@MainActor final class ChatModel: ObservableObject {
    typealias Streamer = (ChatRequest, @escaping (StreamUpdate) async -> Void) async throws -> Void
    @Published var appearance: AppearancePreferences {
        didSet { if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: "appearance") } }
    }
    @Published var preferences: Preferences { didSet { persist() } }
    @Published var defaultModel: ModelChoice? {
        didSet {
            if let defaultModel, let data = try? JSONEncoder().encode(defaultModel) { defaults.set(data, forKey: "defaultModel") }
            else { defaults.removeObject(forKey: "defaultModel") }
        }
    }
    @Published var modelList: [ModelChoice] = [] {
        didSet { if let data = try? JSONEncoder().encode(modelList) { defaults.set(data, forKey: "modelList") } }
    }
    @Published var catalogs: [Provider: Catalog] = [:]
    @Published var draft = "" { didSet { if !draft.isEmpty { selectingModel = false } } }
    @Published var selectingModel = false
    @Published var showingModelPicker = false
    @Published var attachments: [Attachment] = []
    @Published var messages: [Message] = [] { didSet { conversationDirty = true } }
    @Published var history: [ConversationSummary] = []
    @Published var historyError: String?
    @Published var openingConversation = false
    @Published var showingHistory = false
    @Published var historyQuery = "" { didSet { filterHistory() } }
    @Published private(set) var historyMatches: [UUID]?
    @Published private(set) var searchingHistory = false
    @Published var selectedHistoryID: UUID?
    @Published private(set) var canReturnToHistory = false
    @Published var manualHistoryHeight: CGFloat?
    @Published var inputHeight: CGFloat = 26
    @Published var manualInputHeight: CGFloat = 26
    @Published var panelWidth: CGFloat = 700
    @Published var threadHeight: CGFloat = 44
    @Published var manualThreadHeight: CGFloat?
    @Published var streaming = false
    @Published var webSearch = false { didSet { defaults.set(webSearch, forKey: "webSearchEnabled") } }
    @Published var error: String?
    @Published var refreshing = false
    var resize: ((NSSize) -> Void)?
    var openSettings: (() -> Void)?
    var presentFilePicker: (() -> Void)?
    var newConversation: (() -> Void)?
    var focusComposer: (() -> Void)?
    var resizeOrigin: NSPoint?
    var updateShortcut: ((UInt32, UInt32, String) -> Bool)?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var lastRequest: ChatRequest?
    private let defaults: UserDefaults
    private let streamer: Streamer
    private var historyStore: ConversationStore?
    private var deletingConversationID: UUID?
    private var conversationID = UUID()
    private var conversationCreated = Date()
    private var conversationDirty = false
    private var historySearchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, historyStore: ConversationStore? = nil, streamer: @escaping Streamer = Providers.stream) {
        self.defaults = defaults
        defaultModel = defaults.data(forKey: "defaultModel").flatMap { try? JSONDecoder().decode(ModelChoice.self, from: $0) }
        appearance = defaults.data(forKey: "appearance").flatMap { try? JSONDecoder().decode(AppearancePreferences.self, from: $0) } ?? AppearancePreferences()
        self.historyStore = historyStore
        self.history = historyStore?.summaries ?? []
        self.streamer = streamer
        self.webSearch = defaults.bool(forKey: "webSearchEnabled")
        preferences = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        preferences.models.removeValue(forKey: "cursor"); preferences.transports.removeValue(forKey: "cursor")
        for provider in Provider.allCases {
            let cached = defaults.stringArray(forKey: "catalog.\(provider.rawValue)")
            let models = (cached ?? provider.defaults).filter(provider.accepts)
            catalogs[provider] = Catalog(models: models, detail: "Checking login…", ready: false)

        }
        let saved = defaults.data(forKey: "modelList").flatMap { try? JSONDecoder().decode([ModelChoice].self, from: $0) }
        var seen = Set<ModelChoice>()
        modelList = (saved ?? ModelChoice.defaults).filter { seen.insert($0).inserted }
        if modelList.isEmpty { modelList = ModelChoice.defaults }
        if let data = try? JSONEncoder().encode(modelList) { defaults.set(data, forKey: "modelList") }
    }
    func selectModel(_ choice: ModelChoice) {
        preferences.provider = choice.provider; preferences.models[choice.provider.rawValue] = choice.model
    }
    func addModel(_ choice: ModelChoice) {
        guard choice.provider.accepts(choice.model), !modelList.contains(choice) else { return }
        modelList.append(choice)
    }
    func removeModel(_ choice: ModelChoice) {
        guard modelList.count > 1 else { return }
        modelList.removeAll { $0 == choice }
        if defaultModel == choice { defaultModel = nil }
        if provider == choice.provider && model == choice.model, let first = modelList.first { selectModel(first) }
    }
    func moveModel(_ source: ModelChoice, to target: ModelChoice) {
        guard source != target, let from = modelList.firstIndex(of: source), let to = modelList.firstIndex(of: target) else { return }
        var reordered = modelList; reordered.remove(at: from)
        reordered.insert(source, at: to); modelList = reordered
    }
    func enableLocalHistory() {
        do { historyStore = try .local(); history = historyStore?.summaries ?? [] }
        catch { historyError = "Could not open local chat history: \(error.localizedDescription)" }
    }
    var provider: Provider { preferences.provider }
    var model: String { preferences.model(provider) }
    var selectableModels: [ModelChoice] {
        modelList.filter { choice in
            guard let catalog = catalogs[choice.provider], catalog.ready else { return false }
            return !catalog.live || catalog.models.contains(choice.model)
        }
    }
    var selectedModelReady: Bool { selectableModels.contains(ModelChoice(provider: provider, model: model)) }
    private func applyStartingModel() {
        if let defaultModel, selectableModels.contains(defaultModel) { selectModel(defaultModel) }
        else if !selectedModelReady, let first = selectableModels.first { selectModel(first) }
    }
    var canSearchWeb: Bool { provider == .anthropic || preferences.transport(provider) != .cli }
    var webSearchActive: Bool { webSearch && canSearchWeb }
    var filteredHistory: [ConversationSummary] {
        guard let historyMatches else { return history }
        let ids = Set(historyMatches)
        return history.filter { ids.contains($0.id) }
    }
    var historyHeight: CGFloat { manualHistoryHeight ?? min(308, max(88, CGFloat(history.count) * 44)) }
    func cycleModel(_ direction: Int) {
        guard !streaming, !showingHistory, draft.isEmpty || showingModelPicker else { return }
        let choices = selectableModels
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex { $0.provider == provider && $0.model == model }
        let index = current.map { ($0 + direction + choices.count) % choices.count } ?? (direction > 0 ? 0 : choices.count - 1)
        selectModel(choices[index])
        selectingModel = !showingModelPicker
    }
    func stepEffort(_ direction: Int) {
        guard !streaming else { return }
        let levels = Effort.allCases
        let current = levels.firstIndex(of: preferences.effort) ?? 0
        preferences.effort = levels[min(levels.count - 1, max(0, current + direction))]
    }
    @discardableResult func endModelSelection() -> Bool {
        let active = selectingModel || showingModelPicker; selectingModel = false; showingModelPicker = false; return active
    }
    func showHistory(preservingSearch: Bool = false) {
        selectingModel = false; showingModelPicker = false
        saveConversation()
        if !preservingSearch { historyQuery = ""; selectedHistoryID = nil }
        showingHistory = true; filterHistory()
    }
    func closeHistory() { showingHistory = false; historySearchTask?.cancel(); searchingHistory = false }
    func returnToHistory() -> Bool {
        guard canReturnToHistory else { return false }
        showHistory(preservingSearch: true); return true
    }
    private func filterHistory() {
        historySearchTask?.cancel()
        guard showingHistory, !ConversationSearch.terms(historyQuery).isEmpty, let historyStore else {
            historyMatches = nil; searchingHistory = false; return
        }
        let query = historyQuery
        historyMatches = []; searchingHistory = true
        historySearchTask = Task { [weak self] in
            do {
                // Coalesce fast typing before any disk work. Later keystrokes
                // reuse a text-only cache rather than reloading attachments.
                try await Task.sleep(nanoseconds: 60_000_000)
                let matches = try await historyStore.search(query)
                guard let self, !Task.isCancelled, self.showingHistory, self.historyQuery == query else { return }
                self.historyMatches = matches; self.searchingHistory = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.searchingHistory = false; self.historyError = "Could not search chat history: \(error.localizedDescription)"
            }
        }
    }
    func persist() { if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences") } }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        let transports = preferences.transports
        await withTaskGroup(of: (Provider, Catalog).self) { group in
            for provider in Provider.allCases {
                group.addTask { (provider, await Providers.catalog(provider, transport: transports[provider.rawValue] ?? .automatic)) }
            }
            for await (provider, received) in group {
                guard preferences.transport(provider) == (transports[provider.rawValue] ?? .automatic) else { continue }
                var catalog = received
                if catalog.live { defaults.set(catalog.models, forKey: "catalog.\(provider.rawValue)") }
                else if let cached = defaults.stringArray(forKey: "catalog.\(provider.rawValue)") {
                    catalog.models = cached.filter(provider.accepts)
                    catalog.detail = catalog.detail.replacingOccurrences(of: "fallback catalog", with: "cached catalog").replacingOccurrences(of: "Fallback catalog.", with: "Using the last synced catalog.")
                }
                catalogs[provider] = catalog

            }
        }
        refreshing = false
        if messages.isEmpty && draft.isEmpty && !streaming { applyStartingModel() }
    }
    func reset() {
        applyStartingModel()
        selectingModel = false; showingModelPicker = false
        stop()
        generation = UUID(); task?.cancel(); task = nil
        draft = ""; attachments = []; messages = []; streaming = false; error = nil
        inputHeight = 26; manualInputHeight = 26; lastRequest = nil
        manualThreadHeight = nil; threadHeight = 44
        resizeOrigin = nil
        closeHistory(); historyQuery = ""; selectedHistoryID = nil; canReturnToHistory = false; manualHistoryHeight = nil
        conversationID = UUID(); conversationCreated = Date(); conversationDirty = false
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; streaming = false
        for index in messages.indices where messages[index].pending { messages[index].pending = false }
        saveConversation()
    }
    func saveConversation() {
        guard deletingConversationID != conversationID, conversationDirty, messages.contains(where: { $0.role == .user }), let historyStore else { return }
        let summary = ConversationSummary(id: conversationID, title: Conversation.title(for: messages), createdAt: conversationCreated, updatedAt: Date())
        var savedMessages = messages
        for index in savedMessages.indices { savedMessages[index].pending = false }
        let record = Conversation(summary: summary, messages: savedMessages, provider: provider, model: model, effort: preferences.effort, transport: preferences.transport(provider))
        history.removeAll { $0.id == summary.id }; history.insert(summary, at: 0)
        conversationDirty = false
        historyStore.save(record) { [weak self] error in
            if let error { Task { @MainActor in self?.historyError = "Could not save chat history: \(error.localizedDescription)" } }
        }
        if showingHistory { filterHistory() }
    }
    func deleteConversation(_ id: UUID) async {
        guard let historyStore, deletingConversationID == nil, !openingConversation else { return }
        if conversationID == id { stop() }
        deletingConversationID = id
        defer { deletingConversationID = nil }
        do {
            try await historyStore.delete(id)
            let visible = filteredHistory
            let row = visible.firstIndex { $0.id == id } ?? 0
            history.removeAll { $0.id == id }
            if selectedHistoryID == id {
                let remaining = filteredHistory
                selectedHistoryID = remaining.isEmpty ? nil : remaining[min(row, remaining.count - 1)].id
            }
            if conversationID == id {
                messages = []; conversationID = UUID(); conversationCreated = Date()
                conversationDirty = false; lastRequest = nil; canReturnToHistory = false
                error = nil; threadHeight = 44; manualThreadHeight = nil
            }
            historyError = nil
        } catch { historyError = "Could not delete this conversation: \(error.localizedDescription)" }
    }
    func openConversation(_ id: UUID) async -> Bool {
        guard let historyStore, !openingConversation else { return false }
        stop(); let current = generation; openingConversation = true
        defer { openingConversation = false }
        do {
            let record = try await historyStore.load(id)
            guard generation == current else { return false }
            messages = record.messages; conversationID = record.summary.id; conversationCreated = record.summary.createdAt
            preferences.provider = record.provider; preferences.effort = record.effort
            preferences.models[record.provider.rawValue] = record.model
            preferences.transports[record.provider.rawValue] = record.transport
            draft = ""; attachments = []; error = nil; lastRequest = nil
            inputHeight = 26; manualInputHeight = 26; manualThreadHeight = nil; threadHeight = 44
            conversationDirty = false
            selectedHistoryID = id; canReturnToHistory = true
            closeHistory()
            return true
        } catch { historyError = "Could not open this conversation: \(error.localizedDescription)"; return false }
    }
    func finish() { stop(); historyStore?.flush() }
    func send() {
        guard !streaming else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // The sent message owns its attachments. Clearing the composer cannot
        // remove the thumbnail or the image from later conversation requests.
        messages.append(Message(role: .user, text: text, attachments: attachments))
        draft = ""; attachments = []; inputHeight = 26; manualInputHeight = 26
        begin(ChatRequest(provider: provider, model: model, effort: preferences.effort,
            transport: preferences.transport(provider), messages: messages, webSearch: webSearch && canSearchWeb))
    }
    func retry() {
        guard !streaming, let previous = lastRequest else { return }
        messages = previous.messages
        begin(ChatRequest(provider: provider, model: model, effort: preferences.effort,
            transport: preferences.transport(provider), messages: messages, webSearch: previous.webSearch && canSearchWeb))
    }
    private func begin(_ request: ChatRequest) {
        error = nil; streaming = true; generation = UUID(); let current = generation
        lastRequest = request
        let assistant = Message(role: .assistant, text: "", pending: true, author: request.provider.title)
        messages.append(assistant)
        saveConversation()
        let streamer = self.streamer
        task = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var first: Double?; var count = 0
            do {
                try await streamer(request) { [weak self] update in
                    guard let self, self.generation == current,
                          let index = self.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                    switch update {
                    case .text(let text):
                        if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                        count += 1; self.messages[index].text += text
                    case .replaceText(let text): self.messages[index].text = text
                    case .activity(let activity): self.messages[index].activity = activity
                    }
                }
                metric(["kind": "stream", "provider": request.provider.rawValue, "model": request.model,
                    "ttft_ms": first ?? -1, "total_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000, "deltas": count])
            } catch {
                if let self, self.generation == current, !Task.isCancelled { self.error = error.localizedDescription }
            }
            if let self, self.generation == current {
                self.streaming = false
                if let index = self.messages.firstIndex(where: { $0.id == assistant.id }) { self.messages[index].pending = false }
                self.saveConversation()
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
        presentFilePicker?()
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
