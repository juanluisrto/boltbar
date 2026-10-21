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
    /// What Settings shows for each provider: its CLI's sign-in and whether an API key is saved.
    @Published var cliStatus: [Provider: CLIStatus] = [:]
    @Published var keyStatus: [Provider: KeyStatus] = [:]
    @Published var draft = "" { didSet { if !draft.isEmpty { selectingModel = false } } }
    @Published var selectingModel = false
    @Published var showingModelPicker = false
    @Published var attachments: [Attachment] = []
    @Published var messages: [Message] = [] { didSet { conversationDirty = true } }
    /// Messages written while a reply streams. They go out together as the
    /// next turn, and only on their own after a turn that finished normally.
    @Published private(set) var queue: [Message] = [] { didSet { conversationDirty = true } }
    /// Stop, a provider error or reopening a chat holds the queue until an
    /// explicit send, so pending messages never go out unexpectedly.
    @Published private(set) var queueHeld = false
    @Published private(set) var editingQueuedID: UUID?
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
    /// Agent mode: the CLI acts in the selected project and asks before acting.
    @Published var agentMode = false { didSet { defaults.set(agentMode, forKey: "agentModeEnabled") } }
    @Published var agentSettings = AgentSettings() {
        didSet { if let data = try? JSONEncoder().encode(agentSettings) { defaults.set(data, forKey: "agentSettings") } }
    }
    @Published var selectingAgent = false
    @Published var showingAgentPicker = false
    @Published private(set) var pendingProjectRemoval: UUID?
    /// Full access waits for a second → (or click) on this project.
    @Published private(set) var pendingFullAccess: UUID?
    @Published private(set) var pendingApproval: ApprovalRequest?
    /// The project whose turn asked; a permission change there can answer the request.
    private var pendingApprovalProject: UUID?
    /// The agent turn now running, so a permission change reaches it.
    private var runningAgent: (project: UUID, provider: Provider, launched: AgentPermission, control: AgentControl)?
    /// Bumped when a chat opens, so the thread scrolls to its end.
    @Published private(set) var threadRevision = 0
    // Streamed text waits here briefly, so a fast reply redraws the bar ~30 times a second, not per token.
    private var streamBuffer = ""
    private var streamBufferID: UUID?
    private var streamFlush: Task<Void, Never>?
    /// This chat's Claude Code session or Codex thread; agent turns continue it.
    @Published private(set) var agentSession: AgentSession? { didSet { if agentSession != oldValue { conversationDirty = true } } }
    /// A short line above the toolbar: plain ones clear after a few seconds, one with actions stays until answered.
    @Published private(set) var notice: Notice?
    /// Selects the whole chat in its text view; set by the thread. False when there's nothing to select.
    var selectChat: (() -> Bool)?
    private var noticeTask: Task<Void, Never>?
    @Published private(set) var licenseState = LicenseState.checking
    var license: License? { if case .licensed(let license) = licenseState { return license }; return nil }
    var licensePublicKey = LicenseKey.bundled
    var licenseStore = LicenseStore.keychain
    var support: SupportSchedule
    /// A Settings section to scroll to when Settings opens, such as "license".
    @Published var settingsTarget: String?
    @Published var showingHelp = false
    @Published var error: String?
    @Published var refreshing = false
    var resize: ((NSSize) -> Void)?
    var openSettings: (() -> Void)?
    var presentFilePicker: (() -> Void)?
    var presentFolderPicker: (() -> Void)?
    var newConversation: (() -> Void)?
    var focusComposer: (() -> Void)?
    var resizeOrigin: NSPoint?
    var updateShortcut: ((UInt32, UInt32, String) -> Bool)?
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    static let interruptDelay: TimeInterval = 0.6
    private var lastQueued = -TimeInterval.infinity
    private var barVisible = true
    /// A turn ended while the bar was hidden, so its reply hasn't been read.
    private(set) var unreadReply = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var lastTurn: (messages: [Message], webSearch: Bool)?
    private let defaults: UserDefaults
    private let streamer: Streamer
    private var historyStore: ConversationStore?
    private var deletingConversationID: UUID?
    private var conversationID = UUID()
    private var conversationCreated = Date()
    private var conversationDirty = false
    private var historySearchTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    /// Requests allowed "in this chat"; cleared with the conversation.
    private var approvedKeys: Set<String> = []

    init(defaults: UserDefaults = .standard, historyStore: ConversationStore? = nil, streamer: @escaping Streamer = Providers.stream) {
        self.defaults = defaults
        support = SupportSchedule(defaults: defaults)
        defaultModel = defaults.data(forKey: "defaultModel").flatMap { try? JSONDecoder().decode(ModelChoice.self, from: $0) }
        appearance = defaults.data(forKey: "appearance").flatMap { try? JSONDecoder().decode(AppearancePreferences.self, from: $0) } ?? AppearancePreferences()
        self.historyStore = historyStore
        self.history = historyStore?.summaries ?? []
        self.streamer = streamer
        self.webSearch = defaults.bool(forKey: "webSearchEnabled")
        self.agentMode = defaults.bool(forKey: "agentModeEnabled")
        preferences = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        preferences.models.removeValue(forKey: "cursor"); preferences.transports.removeValue(forKey: "cursor")
        if let saved = defaults.data(forKey: "agentSettings").flatMap({ try? JSONDecoder().decode(AgentSettings.self, from: $0) }) { agentSettings = saved }
        if agentSettings.projects.isEmpty { agentSettings = AgentSettings() }
        agentSettings.expireFullAccess()
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
    var queuePaused: Bool { queueHeld || editingQueuedID != nil }
    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    var canSearchWeb: Bool { provider == .anthropic || preferences.transport(provider) != .cli }
    /// Web search stays off in agent mode: web content plus tools is how data leaves a machine.
    var webSearchActive: Bool { webSearch && canSearchWeb && !agentMode }
    var agentProject: AgentProject? { agentSettings.selectedProject }
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
        let active = selectingModel || showingModelPicker || selectingAgent || showingAgentPicker
        selectingModel = false; showingModelPicker = false; selectingAgent = false; showingAgentPicker = false; pendingProjectRemoval = nil; pendingFullAccess = nil
        return active
    }

    // MARK: Agent mode

    /// ⌘J and the terminal button. Turning it on selects the chip, so the arrows adjust it at once;
    /// ↵ on the chip keeps it selected either way, so ↵ again flips it back.
    func toggleAgentMode(keepingSelection: Bool = false) {
        agentMode.toggle()
        selectingModel = false; showingModelPicker = false; pendingProjectRemoval = nil; pendingFullAccess = nil
        selectingAgent = agentMode || keepingSelection; showingAgentPicker = false
        if agentMode { agentSettings.expireFullAccess() }
    }
    /// Tab with an empty message walks to the model chip, then the agent chip, and stays there; ⇧Tab walks back.
    func switchChipSelection(forward: Bool) -> Bool {
        guard !showingHistory else { return false }
        let onChip = selectingModel || showingModelPicker || selectingAgent || showingAgentPicker
        let toAgent = forward && onChip
        showingModelPicker = false; showingAgentPicker = false
        selectingModel = !toAgent; selectingAgent = toAgent
        pendingProjectRemoval = nil; pendingFullAccess = nil
        return true
    }
    func cycleProject(_ direction: Int) {
        let projects = agentSettings.projects
        guard !projects.isEmpty else { return }
        let current = projects.firstIndex { $0.id == agentProject?.id } ?? 0
        agentSettings.selected = projects[(current + direction + projects.count) % projects.count].id
        pendingProjectRemoval = nil; pendingFullAccess = nil
    }
    func selectProject(_ id: UUID) { agentSettings.selected = id; pendingProjectRemoval = nil; pendingFullAccess = nil }
    /// ← → steps through the permissions, remembered per project. ← while Full waits for its second press stays on Edit.
    func stepPermission(_ direction: Int) {
        guard let project = agentProject else { return }
        if direction < 0, pendingFullAccess == project.id { pendingFullAccess = nil; return }
        let levels = AgentPermission.allCases
        let current = levels.firstIndex(of: project.permission) ?? 1
        choosePermission(levels[min(levels.count - 1, max(0, current + direction))], for: project.id)
    }
    /// From the chip and its popover Full takes a second press; Settings sets it directly.
    func choosePermission(_ permission: AgentPermission, for id: UUID) {
        guard let current = agentSettings.projects.first(where: { $0.id == id })?.permission else { return }
        if permission == .full, current != .full, pendingFullAccess != id { pendingProjectRemoval = nil; pendingFullAccess = id; return }
        setPermission(permission, for: id)
    }
    func setPermission(_ permission: AgentPermission, for id: UUID) {
        pendingProjectRemoval = nil; pendingFullAccess = nil
        // Pressing → again on Full mustn't restart its day.
        guard let index = agentSettings.projects.firstIndex(where: { $0.id == id }), agentSettings.projects[index].permission != permission else { return }
        agentSettings.projects[index].permission = permission
        agentSettings.projects[index].fullSince = permission == .full ? Date() : nil
        applyToRunningTurn(permission, project: id)
    }
    /// A change mid-turn applies at once: Claude Code switches mode, Boltbar answers requests by the new light,
    /// and an open request it now decides is answered. Codex in Look or Full asks for nothing, so it keeps its
    /// sandbox until the reply ends.
    private func applyToRunningTurn(_ permission: AgentPermission, project id: UUID) {
        guard let run = runningAgent, run.project == id else { return }
        run.control.change(to: permission)
        if let pending = pendingApproval, pendingApprovalProject == id, let decision = Agent.autoDecision(pending, permission: permission) {
            resolveApproval(decision)
        }
        if run.provider == .openai, run.launched == .look || run.launched == .full, permission != run.launched {
            show(notice: "Codex keeps its \(run.launched.title) permission until this reply ends.")
        }
    }
    /// Adds a folder (or selects it if already listed) and makes it the agent's project.
    func addProject(path: String) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = agentSettings.projects.first(where: { $0.path == path }) { agentSettings.selected = existing.id; return }
        let project = AgentProject(path: path)
        agentSettings.projects.append(project); agentSettings.selected = project.id
    }
    /// ⌫ asks first; the second press removes the project from the list. The folder is untouched.
    func requestProjectRemoval() {
        guard let project = agentProject else { return }
        pendingFullAccess = nil
        if pendingProjectRemoval == project.id { removeProject(project.id) } else { pendingProjectRemoval = project.id }
    }
    func removeProject(_ id: UUID) {
        guard agentSettings.projects.count > 1, let index = agentSettings.projects.firstIndex(where: { $0.id == id }) else { pendingProjectRemoval = nil; pendingFullAccess = nil; return }
        agentSettings.projects.remove(at: index)
        if agentSettings.selected == id { agentSettings.selected = agentSettings.projects[min(index, agentSettings.projects.count - 1)].id }
        pendingProjectRemoval = nil; pendingFullAccess = nil
    }
    func chooseProjectFolder() { presentFolderPicker?() }
    /// Waits for the user's answer; a request already allowed in this chat goes through.
    /// The project's light, as it is now, decides first; then "allow in this chat"; then the user.
    func askApproval(_ request: ApprovalRequest, project: UUID? = nil) async -> ApprovalDecision {
        if let project, let level = agentSettings.projects.first(where: { $0.id == project })?.permission,
           let decision = Agent.autoDecision(request, permission: level) { return decision }
        if approvedKeys.contains(request.key) { return .allow }
        approvalContinuation?.resume(returning: .deny)
        pendingApproval = request; pendingApprovalProject = project
        return await withCheckedContinuation { approvalContinuation = $0 }
    }
    func resolveApproval(_ decision: ApprovalDecision) {
        guard let request = pendingApproval, let continuation = approvalContinuation else { return }
        if decision == .allowForChat { approvedKeys.insert(request.key) }
        pendingApproval = nil; approvalContinuation = nil; pendingApprovalProject = nil
        continuation.resume(returning: decision)
    }

    // MARK: Supporter license

    /// At launch, off the main thread, so the shortcut never waits on the Keychain.
    func loadLicense(allowInteraction: Bool = false) async {
        support.started()
        let store = licenseStore
        do {
            let saved = try await Task.detached { try store.load(allowInteraction) }.value
            guard let saved, let publicKey = licensePublicKey, let license = try? LicenseKey.verify(saved, with: publicKey) else { licenseState = .unlicensed; return }
            licenseState = .licensed(license)
        } catch { licenseState = .locked(error.localizedDescription) }
    }
    /// Checks a pasted key before saving it; the error says what's wrong with it.
    func enterLicense(_ key: String) throws {
        guard let publicKey = licensePublicKey else { throw AppError("License keys are checked in release builds.") }
        let license = try LicenseKey.verify(key, with: publicKey)
        try licenseStore.save(key.filter { !$0.isWhitespace })
        licenseState = .licensed(license)
        if notice?.actions.isEmpty == false { notice = nil }
    }
    func removeLicense() throws { try licenseStore.remove(); licenseState = .unlicensed }
    func buyLicense() { NSWorkspace.shared.open(License.buyURL) }
    func recoverLicense() { NSWorkspace.shared.open(License.recoveryURL) }
    func showLicenseSettings() { settingsTarget = "license"; openSettings?() }
    /// A finished reply may bring a gentle reminder to an unlicensed copy, on SupportSchedule's terms:
    /// never during a reply or a permission request, never over another message, only where it can be seen.
    func askForSupportIfDue() {
        guard licenseState == .unlicensed, licensePublicKey != nil, !streaming, pendingApproval == nil, barVisible, !showingHistory,
              error == nil, notice == nil, support.due else { return }
        support.nudged()
        show(notice: "Boltbar is free and open source. If it's useful to you, a supporter license keeps it going.", actions: [
            NoticeAction(title: "Buy") { [weak self] in self?.buyLicense() },
            NoticeAction(title: "Enter key") { [weak self] in self?.showLicenseSettings() },
            NoticeAction(title: "Not now") {},
        ])
    }

    // MARK: Help and commands

    static let commands = ["/help", "/new", "/agent", "/terminal"]
    /// Commands run locally and are never sent to a model.
    private func runCommand(_ text: String) -> Bool {
        switch text.lowercased() {
        case "/help": showHelp()
        case "/new": newConversation?()
        case "/agent": toggleAgentMode()
        case "/terminal": copyTerminalCommand()
        default: return false
        }
        return true
    }
    /// Copies the command that continues this chat's agent session in a terminal.
    func copyTerminalCommand() {
        guard let session = agentSession else {
            show(notice: "No agent session yet: send a message in agent mode first."); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.terminalCommand, forType: .string)
        show(notice: "Copied: \(session.terminalCommand)")
    }
    func show(notice text: String, actions: [NoticeAction] = []) {
        notice = Notice(text: text, actions: actions); noticeTask?.cancel()
        guard actions.isEmpty else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }
    func perform(_ action: NoticeAction) { notice = nil; noticeTask?.cancel(); action.run() }
    /// ⌘+, ⌘− and ⌘0: the text of every chat, saved for next time.
    func stepTextSize(_ step: Int) {
        appearance.stepTextSize(step)
        let size = Int(appearance.chatTextSize), sizes = AppearancePreferences.textSizes
        let limit = size == Int(sizes.last!) && step > 0 ? ", the largest" : size == Int(sizes.first!) && step < 0 ? ", the smallest" : ""
        show(notice: appearance.textSize == nil ? "Text size \(size) pt, the standard" : "Text size \(size) pt\(limit) · ⌘0 resets")
    }
    func showHelp() { endModelSelection(); closeHistory(); showingHelp = true }
    func closeHelp() { showingHelp = false }
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
        await withTaskGroup(of: (Provider, Catalog, CLIStatus, KeyStatus).self) { group in
            for provider in Provider.allCases {
                group.addTask {
                    let cli = await CLI.status(provider)
                    let key: KeyStatus
                    do { key = try Keychain.key(provider) == nil ? .none : .saved } catch { key = .needsAccess }
                    return (provider, await Providers.catalog(provider, transport: transports[provider.rawValue] ?? .automatic, cli: cli), cli, key)
                }
            }
            for await (provider, received, cli, key) in group {
                cliStatus[provider] = cli; keyStatus[provider] = key
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
    /// Whether a summon should bring this chat back instead of replacing it:
    /// a reply still streaming, messages waiting to go out (held or not), or
    /// a reply that finished out of sight.
    var keepsChatOnSummon: Bool { streaming || !queue.isEmpty || unreadReply }
    /// The global shortcut. An idle chat gives way to a new one; a chat that
    /// is still working comes back as it was, so its reply keeps streaming and
    /// its queue still goes out. `newChat` (⌘N) always starts over, stopping
    /// the reply. Returns whether the current chat was kept.
    @discardableResult func summon(newChat: Bool = false) -> Bool {
        defer { barVisible = true; unreadReply = false }
        guard !newChat, keepsChatOnSummon else { reset(); return false }
        selectingModel = false; showingModelPicker = false
        closeHistory()
        return true
    }
    /// The bar left the screen: Esc, Settings.
    func barHidden() { barVisible = false }
    func reset() {
        applyStartingModel()
        selectingModel = false; showingModelPicker = false; selectingAgent = false; showingAgentPicker = false; showingHelp = false
        pendingProjectRemoval = nil; pendingFullAccess = nil
        stop() // Saves any pending messages, held, with the conversation.
        approvedKeys = []; agentSession = nil; notice = nil
        generation = UUID(); task?.cancel(); task = nil
        draft = ""; attachments = []; messages = []; streaming = false; error = nil; unreadReply = false
        queue = []; queueHeld = false; editingQueuedID = nil; lastQueued = -.infinity
        inputHeight = 26; manualInputHeight = 26; lastTurn = nil
        manualThreadHeight = nil; threadHeight = 44
        resizeOrigin = nil
        closeHistory(); historyQuery = ""; selectedHistoryID = nil; canReturnToHistory = false; manualHistoryHeight = nil
        conversationID = UUID(); conversationCreated = Date(); conversationDirty = false
    }
    func stop() {
        flushStreamedText()
        // A stopped turn answers its open permission request with a refusal.
        resolveApproval(.deny)
        generation = UUID(); task?.cancel(); task = nil; streaming = false
        for index in messages.indices where messages[index].pending {
            messages[index].pending = false; messages[index].interrupted = true
        }
        if !queue.isEmpty { queueHeld = true }
        saveConversation()
    }
    func saveConversation() {
        guard deletingConversationID != conversationID, conversationDirty, messages.contains(where: { $0.role == .user }), let historyStore else { return }
        let summary = ConversationSummary(id: conversationID, title: Conversation.title(for: messages), createdAt: conversationCreated, updatedAt: Date())
        var savedMessages = messages
        for index in savedMessages.indices { savedMessages[index].pending = false }
        let record = Conversation(summary: summary, messages: savedMessages, provider: provider, model: model, effort: preferences.effort,
            transport: preferences.transport(provider), queued: queue.isEmpty ? nil : queue, agentSession: agentSession)
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
                messages = []; queue = []; queueHeld = false; editingQueuedID = nil; agentSession = nil
                conversationID = UUID(); conversationCreated = Date()
                conversationDirty = false; lastTurn = nil; canReturnToHistory = false
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
            agentSession = record.agentSession; threadRevision += 1
            preferences.provider = record.provider; preferences.effort = record.effort
            preferences.models[record.provider.rawValue] = record.model
            preferences.transports[record.provider.rawValue] = record.transport
            queue = record.queued ?? []; queueHeld = !queue.isEmpty; editingQueuedID = nil
            draft = ""; attachments = []; error = nil; lastTurn = nil; approvedKeys = []
            inputHeight = 26; manualInputHeight = 26; manualThreadHeight = nil; threadHeight = 44
            conversationDirty = false
            selectedHistoryID = id; canReturnToHistory = true
            closeHistory()
            return true
        } catch { historyError = "Could not open this conversation: \(error.localizedDescription)"; return false }
    }
    func finish() { stop(); historyStore?.flush() }
    /// Return and the send button. While a reply streams, text joins the queue.
    /// With an empty composer, Return sends pending messages now, interrupting
    /// the reply, except just after queueing so a quick double press can't.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, Self.commands.contains(text.lowercased()), runCommand(text) {
            draft = ""; inputHeight = 26; manualInputHeight = 26; return
        }
        guard !text.isEmpty || !attachments.isEmpty else {
            if streaming && clock() - lastQueued < Self.interruptDelay { return }
            sendQueueNow(); return
        }
        // The sent message owns its attachments. Clearing the composer cannot
        // remove the thumbnail or the image from later conversation requests.
        var message = Message(role: .user, text: text, attachments: attachments)
        draft = ""; attachments = []; inputHeight = 26; manualInputHeight = 26
        if let id = editingQueuedID, let index = queue.firstIndex(where: { $0.id == id }) {
            message.id = id; queue[index] = message
        } else if streaming || !queue.isEmpty {
            queue.append(message)
        } else {
            editingQueuedID = nil; messages.append(message)
            begin(webSearch: webSearch && canSearchWeb); return
        }
        // Any explicit send resumes a held queue, keeping its order.
        editingQueuedID = nil; queueHeld = false; lastQueued = clock()
        if streaming { saveConversation() } else { dispatchQueue() }
    }
    /// Interrupt the reply, keeping its partial text, and send every pending
    /// message as one turn. Safe to race with the reply finishing: whichever
    /// runs first empties the queue, and a stopped reply can't dispatch it.
    func sendQueueNow() {
        guard !queue.isEmpty, editingQueuedID == nil else { return }
        if streaming { stop() }
        dispatchQueue()
    }
    /// Editing reuses the composer, so attachments can change too. The message
    /// keeps its place, and the queue waits until the edit is sent or cancelled.
    func editQueued(_ id: UUID) {
        guard editingQueuedID == nil, !hasDraft, let message = queue.first(where: { $0.id == id }) else { return }
        editingQueuedID = id; draft = message.text; attachments = message.attachments
        focusComposer?()
    }
    @discardableResult func cancelQueuedEdit() -> Bool {
        guard editingQueuedID != nil else { return false }
        editingQueuedID = nil; draft = ""; attachments = []; inputHeight = 26; manualInputHeight = 26
        // The reply may have finished during the edit; cancelling isn't a send.
        if !streaming && !queue.isEmpty { queueHeld = true }
        return true
    }
    func removeQueued(_ id: UUID) {
        if editingQueuedID == id { cancelQueuedEdit() }
        queue.removeAll { $0.id == id }
        if queue.isEmpty { queueHeld = false }
        saveConversation()
    }
    private func dispatchQueue() {
        guard !streaming, !queue.isEmpty, editingQueuedID == nil else { return }
        queueHeld = false
        messages.append(contentsOf: queue); queue = []
        begin(webSearch: webSearch && canSearchWeb)
    }
    func retry() {
        guard !streaming, let previous = lastTurn else { return }
        messages = previous.messages; queueHeld = false
        begin(webSearch: previous.webSearch && canSearchWeb)
    }
    /// Providers reject empty turns: a reply stopped before its first word is
    /// left out, and a partial one tells the model it was cut short.
    private func request(webSearch: Bool) -> ChatRequest {
        let context = messages.compactMap { message -> Message? in
            guard message.role == .assistant else { return message }
            if message.text.isEmpty && message.attachments.isEmpty { return nil }
            guard message.interrupted == true else { return message }
            var partial = message; partial.text += "\n\n[Interrupted by the user]"; return partial
        }
        var request = ChatRequest(provider: provider, model: model, effort: preferences.effort,
            transport: preferences.transport(provider), messages: context, webSearch: webSearch && !agentMode)
        if agentMode, let project = agentProject {
            agentSettings.expireFullAccess()
            let permission = agentSettings.projects.first { $0.id == project.id }?.permission ?? project.permission
            let control = AgentControl()
            runningAgent = (project.id, provider, permission, control)
            request.agent = AgentTurn(directory: project.path, permission: permission, resume: resume(in: project.path, context: context), control: control) { [weak self] approval in
                await self?.askApproval(approval, project: project.id) ?? .deny
            }
        }
        return request
    }
    /// The chat's session continues when it belongs to this CLI and folder and Boltbar's copy still holds the last
    /// message it saw; otherwise (another project, a retry, an edit) a new session gets the whole chat.
    private func resume(in directory: String, context: [Message]) -> AgentResume? {
        guard let session = agentSession, session.provider == provider, session.directory == directory,
              let at = messages.firstIndex(where: { $0.id == session.seen }) else { return nil }
        let unseen = Set(messages[(at + 1)...].map(\.id))
        var fresh = context.filter { unseen.contains($0.id) }
        guard !fresh.isEmpty else { return nil }
        if messages[at].interrupted == true { fresh.insert(Message(role: .user, text: "[Your previous reply was interrupted by the user.]"), at: 0) }
        return AgentResume(id: session.id, messages: fresh)
    }
    private func begin(webSearch: Bool) {
        let request = request(webSearch: webSearch)
        error = nil; streaming = true; generation = UUID(); let current = generation
        lastTurn = (messages, webSearch)
        let assistant = Message(role: .assistant, text: "", pending: true, author: request.provider.title)
        messages.append(assistant)
        saveConversation()
        let streamer = self.streamer
        task = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var first: Double?; var count = 0, failed = false
            do {
                try await streamer(request) { [weak self] update in
                    guard let self, self.generation == current,
                          let index = self.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                    switch update {
                    case .text(let text):
                        if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                        count += 1; self.bufferStreamedText(text, for: assistant.id)
                    case .replaceText(let text): self.flushStreamedText(); self.messages[index].text = text
                    case .activity(let activity): self.messages[index].activity = activity
                    case .agentSession(let id):
                        // From here on the session holds this exchange, even if it's stopped or fails.
                        if let agent = request.agent { self.agentSession = AgentSession(provider: request.provider, directory: agent.directory, id: id, seen: assistant.id) }
                    case .step(var step):
                        // A step keeps the place in the reply where it began, so it shows between the words around it.
                        self.flushStreamedText()
                        var steps = self.messages[index].steps ?? []
                        if let at = steps.firstIndex(where: { $0.id == step.id }) { step.at = steps[at].at; steps[at] = step }
                        else { step.at = self.messages[index].text.count; steps.append(step) }
                        self.messages[index].steps = steps
                    }
                }
                metric(["kind": "stream", "provider": request.provider.rawValue, "model": request.model,
                    "ttft_ms": first ?? -1, "total_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000, "deltas": count])
            } catch {
                failed = true
                if let self, self.generation == current, !Task.isCancelled { self.error = error.localizedDescription }
            }
            self?.flushStreamedText()
            if let self, self.runningAgent?.control === request.agent?.control { self.runningAgent = nil }
            if let self, self.generation == current {
                self.streaming = false
                if let index = self.messages.firstIndex(where: { $0.id == assistant.id }) {
                    // A reply cut short by an error must not read as complete in later turns.
                    self.messages[index].pending = false
                    if failed { self.messages[index].interrupted = true }
                }
                if failed && !self.queue.isEmpty { self.queueHeld = true }
                if !self.barVisible { self.unreadReply = true }
                self.saveConversation()
                if !self.queuePaused { self.dispatchQueue() }
                if !failed { self.support.replyFinished(); self.askForSupportIfDue() }
            }
        }
    }
    /// Where relative file links in this chat point: its agent project, else your home folder.
    var linkBase: String { agentSession?.directory ?? (agentMode ? agentProject?.path : nil) ?? NSHomeDirectory() }
    /// Opens a link from a reply when it names a file: in its default app, or in Finder with ⌘ held.
    /// False hands anything else (web addresses, mail) to the system.
    func openLink(_ url: URL, revealInFinder: Bool = NSEvent.modifierFlags.contains(.command)) -> Bool {
        guard let file = LocalLink.fileURL(url, base: linkBase) else { return false }
        guard FileManager.default.fileExists(atPath: file.path) else {
            show(notice: "Couldn't find \(file.path)"); return true
        }
        if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([file]) } else { NSWorkspace.shared.open(file) }
        return true
    }
    private func bufferStreamedText(_ text: String, for id: UUID) {
        if streamBufferID != id { flushStreamedText(); streamBufferID = id }
        streamBuffer += text
        guard streamFlush == nil else { return }
        streamFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            self?.flushStreamedText()
        }
    }
    func flushStreamedText() {
        streamFlush?.cancel(); streamFlush = nil
        defer { streamBuffer = "" }
        guard !streamBuffer.isEmpty, let id = streamBufferID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += streamBuffer
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
            // A dropped folder becomes the agent's project; files are attachments.
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for folder in folders { addProject(path: folder.path) }
            if !folders.isEmpty { agentMode = true; selectingAgent = true }
            let files = urls.filter { !folders.contains($0) }
            if !files.isEmpty { addURLs(files) }
            return true
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
