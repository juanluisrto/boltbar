import AppKit
import SwiftUI
import XCTest
@testable import BoltbarNative

final class AppearanceTests: XCTestCase {
    func testSelectingThemeAppliesItAndSynchronizesMode() {
        var preferences = AppearancePreferences()
        preferences.customAccent = "5638AA"
        preferences.selectTheme(.mist)
        XCTAssertEqual(preferences.mode, .light)
        XCTAssertEqual(preferences.lightTheme, .mist)
        XCTAssertNil(preferences.customAccent)
        XCTAssertEqual(preferences.theme(for: .dark), ThemeName.mist.palette)
        preferences.mode = .system
        preferences.selectTheme(.midnight)
        XCTAssertEqual(preferences.mode, .dark)
        XCTAssertEqual(preferences.darkTheme, .midnight)
        XCTAssertEqual(preferences.theme(for: .light), ThemeName.midnight.palette)
        preferences.mode = .light
        XCTAssertEqual(preferences.theme(for: .dark), ThemeName.mist.palette)
    }
    func testSystemAndExplicitModesAndCustomAccent() {
        var preferences = AppearancePreferences()
        preferences.mode = .system
        XCTAssertEqual(preferences.theme(for: .light), ThemeName.paper.palette)
        XCTAssertEqual(preferences.theme(for: .dark), ThemeName.graphite.palette)
        preferences.lightTheme = .mist; preferences.darkTheme = .midnight
        XCTAssertEqual(preferences.theme(for: .light), ThemeName.mist.palette)
        XCTAssertEqual(preferences.theme(for: .dark), ThemeName.midnight.palette)
        preferences.mode = .light
        XCTAssertEqual(preferences.theme(for: .dark), ThemeName.mist.palette)
        preferences.customAccent = "5638AA"
        XCTAssertEqual(preferences.theme(for: .dark).accentNS.rgbHex, "5638AA")
        XCTAssertEqual(preferences.theme(for: .dark).errorNS, ThemeName.mist.palette.errorNS)
        preferences.customAccent = nil
        XCTAssertEqual(preferences.theme(for: .dark), ThemeName.mist.palette)
        preferences.mode = .dark
        XCTAssertEqual(preferences.theme(for: .light), ThemeName.midnight.palette)
    }
    @MainActor func testAppearancePersistsAndLegacyCursorPreferencesMigrate() throws {
        let suite = "com.boltbar.tests.appearance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        legacy["provider"] = "cursor"; legacy["models"] = ["cursor": "composer-2.5", "anthropic": "claude-sonnet-5-5"]
        legacy["transports"] = ["cursor": "cli"]; legacy["shortcutLabel"] = "⌘ Space"
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "preferences")
        let model = ChatModel(defaults: defaults)
        XCTAssertEqual(model.provider, .openai)
        XCTAssertNil(model.preferences.models["cursor"]); XCTAssertNil(model.preferences.transports["cursor"])
        XCTAssertEqual(model.preferences.models["anthropic"], "claude-sonnet-5-5")
        XCTAssertEqual(model.preferences.shortcutLabel, "⌘ Space")
        XCTAssertEqual(Provider.allCases, [.openai, .anthropic])
        model.appearance.mode = .system; model.appearance.lightTheme = .mist
        model.appearance.darkTheme = .midnight; model.appearance.customAccent = "5638AA"
        XCTAssertEqual(ChatModel(defaults: defaults).appearance, model.appearance)
    }
    func testLegacyCursorConversationRemainsReadable() throws {
        let record = Conversation(summary: ConversationSummary(id: UUID(), title: "Old chat", createdAt: Date(), updatedAt: Date()),
                                  messages: [Message(role: .assistant, text: "Original response", author: "Cursor")],
                                  provider: .openai, model: "composer-2.5", effort: .low, transport: .cli)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json["provider"] = "cursor"
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.summary.id, record.summary.id)
        XCTAssertEqual(decoded.messages.first?.text, "Original response")
        XCTAssertEqual(decoded.messages.first?.author, "Cursor")
        XCTAssertEqual(decoded.provider, .openai)
    }
    @MainActor func testNativeThemePreviews() async throws {
        guard ProcessInfo.processInfo.environment["BOLTBAR_THEME_SNAPSHOTS"] == "1" else { return }
        _ = NSApplication.shared
        let suite = "com.boltbar.tests.preview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ChatModel(defaults: defaults)
        model.messages = [Message(role: .user, text: "How will the new themes look?"),
                          Message(role: .assistant, text: "## A calmer interface\nThe interface uses **monospaced text**, while chat content stays easy to read.\n- Four themes with softer error colors.\n- Your preferred accent color.\n\n```swift\nlet theme = \"Paper\"\n```", author: "OpenAI")]
        model.manualThreadHeight = 290; model.draft = "Tell me more about these themes"
        model.error = "Could not connect. Check your connection and try again."
        model.history = ["Planning a weekend in the mountains", "A few ideas for Boltbar", "Quick question"].map {
            ConversationSummary(id: UUID(), title: $0, createdAt: Date(), updatedAt: Date())
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".qa-local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFrontRegardless()
        defer { window.close() }
        func capture<V: View>(_ content: V, name: String, size: NSSize) async throws {
            let host = NSHostingView(rootView: ThemedView(model: model) { content })
            window.contentView = host; window.setContentSize(size)
            try await Task.sleep(nanoseconds: 180_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        for theme in ThemeName.allCases {
            model.appearance.mode = theme.isDark ? .dark : .light
            if theme.isDark { model.appearance.darkTheme = theme } else { model.appearance.lightTheme = theme }
            model.panelWidth = 700
            try await capture(ChatBar(model: model), name: "theme-\(theme.rawValue)", size: NSSize(width: 700, height: 460))
            try await capture(SettingsView(model: model), name: "settings-\(theme.rawValue)", size: NSSize(width: 600, height: 700))
            try await capture(HistoryPane(model: model, close: {}).padding(16).background(theme.palette.background),
                              name: "history-\(theme.rawValue)", size: NSSize(width: 420, height: 260))
        }
        model.panelWidth = 420
        try await capture(ChatBar(model: model), name: "theme-narrow", size: NSSize(width: 420, height: 460))
        try await capture(ModelPopover(model: model, close: {}), name: "model-picker", size: NSSize(width: 280, height: 400))
    }
}
