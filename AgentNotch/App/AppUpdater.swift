import AppKit
@preconcurrency import Sparkle

/// Owns Sparkle and brings the app forward when an update alert needs a window.
///
/// Agent Notch often runs as a menu-bar accessory (`LSUIElement`), so Sparkle's
/// standard alert would otherwise appear behind everything or not become key.
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    private let restorePresence: () -> Void

    var updater: SPUUpdater { controller.updater }
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    init(restorePresence: @escaping () -> Void) {
        self.restorePresence = restorePresence
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restorePresence()
    }
}
