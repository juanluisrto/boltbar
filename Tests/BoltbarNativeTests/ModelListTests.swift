import XCTest
@testable import BoltbarNative

final class ModelListTests: XCTestCase {
    @MainActor func testFreshListUsesExactDefaultsRegardlessOfCatalog() {
        let name = "boltbar.defaults.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["gpt-4.1", "gpt-6-sol"], forKey: "catalog.openai")
        let model = ChatModel(defaults: defaults)
        XCTAssertEqual(model.modelList.map(\.model), ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-1"])
        XCTAssertNil(model.defaultModel)
    }
    @MainActor func testListPersistsOrderAndProtectsLastChoice() {
        let name = "boltbar.models.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ChatModel(defaults: defaults)
        let a = ModelChoice(provider: .openai, model: "gpt-4.1")
        let b = ModelChoice(provider: .anthropic, model: "claude-sonnet-5-5")
        model.modelList = [a, b]; model.addModel(a)
        XCTAssertEqual(model.modelList, [a,b])
        model.moveModel(a, to: b); XCTAssertEqual(model.modelList, [b,a])
        model.selectModel(b); model.removeModel(b)
        XCTAssertEqual(model.modelList, [a]); XCTAssertEqual(model.model, a.model)
        model.removeModel(a); XCTAssertEqual(model.modelList, [a])
        let restarted = ChatModel(defaults: defaults)
        XCTAssertEqual(restarted.modelList, [a]); XCTAssertEqual(restarted.model, a.model)
        restarted.catalogs[.openai] = Catalog(models: ["gpt-6-astra"], detail: "", ready: true, live: true)
        XCTAssertEqual(restarted.modelList, [a]); XCTAssertEqual(restarted.model, a.model)
    }
    @MainActor func testLatestUsedAndFixedDefault() {
        let name = "boltbar.default.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ChatModel(defaults: defaults)
        let a = ModelChoice(provider: .openai, model: "gpt-6.1-sol")
        let b = ModelChoice(provider: .anthropic, model: "claude-sonnet-5-5")
        model.catalogs = [.openai: Catalog(models: [a.model], detail: "", ready: true), .anthropic: Catalog(models: [b.model], detail: "", ready: true)]
        model.modelList = [a,b]; model.selectModel(b); model.reset()
        XCTAssertNil(model.defaultModel); XCTAssertEqual(model.model, b.model)
        model.defaultModel = a; model.selectModel(b); model.reset()
        XCTAssertEqual(model.model, a.model)
        XCTAssertEqual(ChatModel(defaults: defaults).defaultModel, a)
        model.removeModel(a); XCTAssertNil(model.defaultModel)
        model.selectModel(b); model.reset(); XCTAssertEqual(model.model, b.model)
    }
    @MainActor func testOnlyConnectedProvidersParticipateWithoutLosingSavedOrder() {
        let name = "boltbar.connected.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ChatModel(defaults: defaults)
        let a = ModelChoice(provider: .openai, model: "gpt-6-astra")
        let b = ModelChoice(provider: .anthropic, model: "claude-sonnet-5-5")
        let c = ModelChoice(provider: .openai, model: "gpt-6-luna")
        model.modelList = [a,b,c]
        model.catalogs = [.openai: Catalog(models: [a.model,c.model], detail: "", ready: true, live: true), .anthropic: Catalog(models: [b.model], detail: "", ready: false)]
        XCTAssertEqual(model.selectableModels, [a,c])
        model.selectModel(a); model.cycleModel(1); XCTAssertEqual(model.model, c.model)
        model.catalogs[.anthropic]?.ready = true
        XCTAssertEqual(model.selectableModels, [a,b,c])
        model.catalogs[.openai]?.models = [c.model]
        XCTAssertEqual(model.selectableModels, [b,c]); XCTAssertEqual(model.modelList, [a,b,c])
    }
    func testCatalogFilterAndVersions() {
        for id in ["gpt-4.1", "gpt-4o", "gpt-5-mini", "gpt-6-sol", "gpt-6.1-sol-2026-10-14", "o3-mini"] { XCTAssertTrue(Provider.openai.accepts(id), id) }
        for id in ["gpt-image-1", "gpt-audio", "gpt-5-pro", "o3-deep-research", "text-embedding-3-large"] { XCTAssertFalse(Provider.openai.accepts(id), id) }
        XCTAssertTrue(ModelChoice(provider: .openai, model: "gpt-6-sol-2026-10-14").otherVersion)
        XCTAssertFalse(ModelChoice(provider: .openai, model: "gpt-6-sol").otherVersion)
        let request = ChatRequest(provider: .openai, model: "gpt-4.1", effort: .low, transport: .api, messages: [])
        XCTAssertNil(Providers.body(request)["reasoning"])
    }
}
