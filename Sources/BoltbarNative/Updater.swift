import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    @Published private(set) var canCheck = false
    @Published var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var pendingInstall: (() -> Void)?
    private weak var model: ChatModel?
    let configured: Bool
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"

    init(model: ChatModel) {
        self.model = model
        configured = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil
        super.init()
        guard configured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(model.$streaming)
            .map { $0 && !$1 }.receive(on: RunLoop.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.automaticallyChecks != value else { return }
                self.automaticallyChecks = value
            }.store(in: &observations)
        model.$streaming.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] streaming in
            guard !streaming, let self, let install = self.pendingInstall else { return }
            self.pendingInstall = nil
            install()
        }.store(in: &observations)
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        controller?.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if model?.streaming == true {
            throw NSError(domain: "com.boltbar.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updates wait for the current response to finish."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard model?.streaming == true else { return false }
        pendingInstall = installHandler
        return true
    }
}

struct UpdateSettings: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        SettingsSection(title: "Updates") {
            HStack {
                Text("Boltbar \(updater.version)")
                Spacer()
                Button("Check now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                .disabled(!updater.configured)
            Text(updater.configured ? "You choose when to install and relaunch. Updates wait for active responses to finish." : "Updates are available in signed release builds.")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
