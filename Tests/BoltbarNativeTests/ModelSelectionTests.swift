import AppKit
import XCTest
@testable import BoltbarNative

final class ModelSelectionTests: XCTestCase {
    @MainActor func testModelCycleWrapsAndEffortClamps() {
        let suite = "boltbar.selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ChatModel(defaults: defaults)
        model.catalogs = [.openai: Catalog(models: ["gpt-6.1-sol"], detail: "", ready: true), .anthropic: Catalog(models: ["claude-haiku-5-5"], detail: "", ready: true)]
        model.modelList = [ModelChoice(provider: .openai, model: "gpt-6.1-sol"), ModelChoice(provider: .anthropic, model: "claude-haiku-5-5")]
        model.preferences.provider = .openai; model.preferences.models["openai"] = "gpt-6.1-sol"
        model.cycleModel(-1)
        XCTAssertEqual(model.provider, .anthropic); XCTAssertTrue(model.selectingModel)
        model.cycleModel(1); XCTAssertEqual(model.provider, .openai)
        model.preferences.effort = .high; model.stepEffort(1); XCTAssertEqual(model.preferences.effort, .high)
        model.stepEffort(-1); XCTAssertEqual(model.preferences.effort, .medium)
        model.draft = "x"; XCTAssertFalse(model.selectingModel)
        model.cycleModel(1); XCTAssertEqual(model.provider, .openai)
        model.draft = ""; XCTAssertFalse(model.selectingModel)
        model.showingHistory = true; model.cycleModel(1); XCTAssertEqual(model.provider, .openai)
        model.showingHistory = false; model.streaming = true; model.cycleModel(1); XCTAssertEqual(model.provider, .openai)
        model.streaming = false; model.draft = "keep this draft"; model.showingModelPicker = true
        model.cycleModel(1); XCTAssertEqual(model.provider, .anthropic)
        XCTAssertFalse(model.selectingModel); XCTAssertEqual(model.draft, "keep this draft")
        XCTAssertTrue(model.endModelSelection()); XCTAssertFalse(model.showingModelPicker)
    }
    @MainActor func testComposerRoutesArrowsOnlyWhenEmptyAndUnmodified() {
        let text = ComposerTextView(frame: .zero)
        var cycles = 0, effort = 0, history = 0, active = false
        text.onCycleModel = { cycles += $0; active = true }
        text.onStepEffort = { guard active else { return false }; effort += $0; return true }
        text.onEndModelSelection = { let old = active; active = false; return old }
        text.onHistory = { history += 1 }
        func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) {
            text.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        key(125); key(124)
        XCTAssertEqual(cycles, 1); XCTAssertEqual(effort, 1); XCTAssertEqual(history, 0)
        key(53); XCTAssertFalse(active)
        key(124); XCTAssertEqual(history, 1)
        text.string = "draft"; key(125); key(124)
        XCTAssertEqual(cycles, 1); XCTAssertEqual(effort, 1); XCTAssertEqual(history, 1)
        text.string = ""; key(125, "", .shift); XCTAssertEqual(cycles, 1)
    }
}
