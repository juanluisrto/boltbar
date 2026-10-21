import AppKit
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}

enum ThemeName: String, Codable, CaseIterable {
    case paper, mist, graphite, midnight
    var title: String { rawValue.capitalized }
    var isDark: Bool { self == .graphite || self == .midnight }
    var palette: ThemePalette {
        switch self {
        case .paper: return ThemePalette(background: "F6F3EC", text: "292824", accent: "39735C", error: "A94442", dark: false)
        case .mist: return ThemePalette(background: "F1F5F9", text: "243247", accent: "4268B3", error: "AD435E", dark: false)
        case .graphite: return ThemePalette(background: "1C1C1E", text: "E8E7E4", accent: "A0CCB8", error: "E79891", dark: true)
        case .midnight: return ThemePalette(background: "151D2B", text: "E0E7F0", accent: "A7B6F5", error: "E6A0B2", dark: true)
        }
    }
}

struct AppearancePreferences: Codable, Equatable {
    var mode: AppearanceMode = .dark
    var lightTheme: ThemeName = .paper
    var darkTheme: ThemeName = .graphite
    var customAccent: String?
    /// The chat's text size in points, for every chat; nil is the standard size.
    var textSize: Double?
    static let standardTextSize = 14.0
    static let textSizes: [Double] = [11, 12, 13, 14, 15, 16, 18, 20, 22, 24]
    var chatTextSize: Double { textSize ?? Self.standardTextSize }
    /// ⌘+ and ⌘− move one size up or down; 0, as ⌘0, goes back to the standard size.
    mutating func stepTextSize(_ step: Int) {
        let next = step == 0 ? Self.standardTextSize
            : step > 0 ? Self.textSizes.first { $0 > chatTextSize } ?? chatTextSize : Self.textSizes.last { $0 < chatTextSize } ?? chatTextSize
        textSize = next == Self.standardTextSize ? nil : next
    }
    mutating func selectTheme(_ theme: ThemeName) {
        if theme.isDark { darkTheme = theme; mode = .dark }
        else { lightTheme = theme; mode = .light }
        customAccent = nil
    }
    func theme(for scheme: ColorScheme) -> ThemePalette {
        let dark = (mode.scheme ?? scheme) == .dark
        let chosen = dark ? (darkTheme.isDark ? darkTheme : .graphite) : (lightTheme.isDark ? .paper : lightTheme)
        var theme = chosen.palette
        if let customAccent, let color = NSColor(hex: customAccent) { theme.accentNS = color }
        return theme
    }
}

/// The text-size keys: ⌘+ (also ⌘=, the same key unshifted), ⌘− and ⌘0.
enum TextSizeKey {
    static func step(_ event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .control, .option]) == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case "+", "=": return 1
        case "-": return -1
        case "0": return 0
        default: return nil
        }
    }
}

struct ThemePalette: Equatable {
    let backgroundNS: NSColor
    let textNS: NSColor
    var accentNS: NSColor
    let errorNS: NSColor
    let dark: Bool
    init(background: String, text: String, accent: String, error: String, dark: Bool) {
        backgroundNS = NSColor(hex: background)!; textNS = NSColor(hex: text)!
        accentNS = NSColor(hex: accent)!; errorNS = NSColor(hex: error)!; self.dark = dark
    }
    var background: Color { Color(nsColor: backgroundNS) }
    var text: Color { Color(nsColor: textNS) }
    var accent: Color { Color(nsColor: accentNS) }
    var error: Color { Color(nsColor: errorNS) }
    var surface: Color { text.opacity(0.06) }
    var border: Color { text.opacity(0.12) }
    var onAccent: Color {
        let rgb = accentNS.usingColorSpace(.sRGB) ?? accentNS
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
                  blue: CGFloat(number & 255) / 255, alpha: 1)
    }
    var rgbHex: String {
        let color = usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}
private struct ThemeKey: EnvironmentKey { static let defaultValue = ThemeName.graphite.palette }
extension EnvironmentValues {
    var boltbarTheme: ThemePalette {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
struct ThemedView<Content: View>: View {
    @ObservedObject var model: ChatModel
    @Environment(\.colorScheme) private var scheme
    let content: Content
    init(model: ChatModel, @ViewBuilder content: () -> Content) { self.model = model; self.content = content() }
    var body: some View {
        let theme = model.appearance.theme(for: scheme)
        content.environment(\.boltbarTheme, theme)
            .foregroundStyle(theme.text).tint(theme.accent)
            .preferredColorScheme(model.appearance.mode.scheme)
    }
}

/// Native popup buttons need an explicit AppKit font; SwiftUI's inherited
/// font is otherwise ignored for their selected value and menu items.
struct InterfacePicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Popup(selection: $selection, options: options, title: title, label: label)
                .frame(width: options.map { (title($0) as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width }.max().map { $0 + 34 } ?? 120, height: 26)
        }
    }
    private struct Popup: NSViewRepresentable {
        @Binding var selection: Value
        let options: [Value]
        let title: (Value) -> String
        let label: String
        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
        func makeNSView(context: Context) -> NSPopUpButton {
            let button = NSPopUpButton()
            button.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            button.menu?.font = button.font
            button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
            button.setAccessibilityLabel(label)
            return button
        }
        func updateNSView(_ button: NSPopUpButton, context: Context) {
            context.coordinator.parent = self
            let titles = options.map(title)
            if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
            button.selectItem(at: options.firstIndex(of: selection) ?? 0)
        }
        final class Coordinator: NSObject {
            var parent: Popup
            init(parent: Popup) { self.parent = parent }
            @objc func changed(_ sender: NSPopUpButton) {
                guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
                parent.selection = parent.options[sender.indexOfSelectedItem]
            }
        }
    }
}

struct InterfaceButtonStyle: ButtonStyle {
    @Environment(\.boltbarTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(theme.text.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.5)
    }
}
