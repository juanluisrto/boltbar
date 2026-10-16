import SwiftUI
import UniformTypeIdentifiers

struct ModelChoice: Codable, Hashable, Identifiable {
    let provider: Provider
    let model: String
    var id: String { provider.rawValue + ":" + model }
    static let defaults: [ModelChoice] = [
        .init(provider: .openai, model: "gpt-6-astra"),
        .init(provider: .openai, model: "gpt-6.1-sol"),
        .init(provider: .openai, model: "gpt-6-luna"),
        .init(provider: .anthropic, model: "claude-sonnet-5-5"),
        .init(provider: .anthropic, model: "claude-opus-5-5"),
        .init(provider: .anthropic, model: "claude-haiku-5-5"),
        .init(provider: .anthropic, model: "claude-fable-5-1")
    ]
    var otherVersion: Bool {
        model.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{8}|preview|experimental|latest", options: .regularExpression) != nil
    }
}

struct ModelSettingsView: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    @State private var addingModel = false
    var body: some View {
        SettingsSection(title: "Models") {
            Text("Drag to set the order for ↑ / ↓ and the model menu.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.modelList) { choice in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityLabel("Drag to reorder")
                            Text(modelTitle(choice.model)).lineLimit(1)
                            Spacer()
                            Text(choice.provider.title).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            if let catalog = model.catalogs[choice.provider], catalog.live, !catalog.models.contains(choice.model) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(theme.error).help("Unavailable in latest sync")
                            }
                            Button { model.removeModel(choice) } label: { Image(systemName: "minus.circle").frame(width: 24, height: 24).contentShape(Rectangle()) }
                                .buttonStyle(.plain).disabled(model.modelList.count == 1).accessibilityLabel("Remove \(modelTitle(choice.model))")
                        }.padding(.vertical, 9).contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: choice.id as NSString) }
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                guard let item = providers.first else { return false }
                                _ = item.loadObject(ofClass: String.self) { id, _ in
                                    Task { @MainActor in
                                        guard let source = model.modelList.first(where: { $0.id == id }) else { return }
                                        model.moveModel(source, to: choice)
                                    }
                                }
                                return true
                            }
                            .contextMenu {
                                Button("Move up") {
                                    if let index = model.modelList.firstIndex(of: choice), index > 0 { model.moveModel(choice, to: model.modelList[index - 1]) }
                                }
                                Button("Move down") {
                                    if let index = model.modelList.firstIndex(of: choice), index + 1 < model.modelList.count { model.moveModel(choice, to: model.modelList[index + 1]) }
                                }
                            }
                        if choice != model.modelList.last { Divider() }
                    }
                }.padding(.trailing, 20)
            }.frame(height: min(240, CGFloat(model.modelList.count) * 44))
            Button { addingModel = true } label: { Label("Add more", systemImage: "plus") }
                .popover(isPresented: $addingModel, arrowEdge: .bottom) {
                    AddModelPopover(model: model, close: { addingModel = false })
                }
        }
    }
}

struct AddModelPopover: View {
    @Environment(\.boltbarTheme) private var theme
    @ObservedObject var model: ChatModel
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var available: [ModelChoice] {
        Provider.allCases.filter { model.catalogs[$0]?.ready == true }.flatMap { provider in
            (model.catalogs[provider]?.models ?? provider.defaults).map { ModelChoice(provider: provider, model: $0) }
        }.filter { query.isEmpty || ($0.model + " " + modelTitle($0.model) + " " + $0.provider.title).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add model").fontWeight(.semibold)
                Spacer()
                Button(model.refreshing ? "Syncing…" : "Refresh") { Task { await model.refresh() } }.disabled(model.refreshing)
            }
            HStack {
                Text(">").foregroundStyle(theme.accent)
                TextField("Search models", text: $query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search models")
            }.padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if available.isEmpty { Text(model.catalogs.values.contains(where: { $0.ready }) ? "No matching models" : "Connect a provider in Connections to add models.").foregroundStyle(.secondary).padding(.vertical, 16) }
                    ForEach(available) { choice in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(modelTitle(choice.model))
                                Text(choice.provider.title).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.modelList.contains(choice) {
                                Image(systemName: "checkmark").foregroundStyle(theme.accent).accessibilityLabel("Already added")
                            } else {
                                Button("Add") { model.addModel(choice); close() }.accessibilityLabel("Add \(modelTitle(choice.model))")
                            }
                        }.padding(.vertical, 9)
                        Divider()
                    }
                }
            }.frame(height: 260)
            ForEach(Provider.allCases) { provider in
                Text(provider.title + " · " + (model.catalogs[provider]?.detail ?? "Suggested catalog"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(width: 380).font(.system(size: 12, design: .monospaced))
            .background(theme.background).onAppear { searchFocused = true }.onExitCommand(perform: close)
    }
}
