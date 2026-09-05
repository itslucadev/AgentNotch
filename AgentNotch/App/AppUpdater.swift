import AppKit
@preconcurrency import Sparkle

/// Owns Sparkle and brings the app forward when an update alert needs a window.
///
/// Agent Notch often runs as a menu-bar accessory (`LSUIElement`), so Sparkle's
/// standard alert would otherwise appear behind everything or not become key.
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    private let restorePresence: () -> Void

    var updater: SPUUpdater { controller.updater }
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    init(restorePresence: @escaping () -> Void) {
        self.restorePresence = restorePresence
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    #if DEBUG
        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            guard updateCheck == .updatesInBackground else { return }
            throw NSError(
                domain: "app.lucabecker.AgentNotch.debug",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Debug builds skip scheduled production update checks."
                ]
            )
        }
    #endif

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
