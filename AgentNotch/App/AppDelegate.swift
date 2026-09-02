import AppKit
import Observation

/// Actions shared by the status item, notch and settings.
struct MenuActions {
    var refreshAll: () -> Void
    var openSettings: () -> Void
    var checkForUpdates: () -> Void
    var canCheckForUpdates: () -> Bool
    var previewLimit: (LimitEvent.Kind) -> Void
    var quit: () -> Void
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var preferences: Preferences!
    private var store: UsageStore!
    private var notch: NotchWindowController!
    private var settings: SettingsWindowController!
    private var statusItem: StatusItemController!
    private var updater: AppUpdater!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences()
        let store = UsageStore(providers: [
            ClaudeOAuthProvider(),
            CursorLocalProvider(),
            CodexLocalProvider(),
        ])
        self.preferences = preferences
        self.store = store

        updater = AppUpdater(restorePresence: { [weak self] in
            self?.applyPresence()
        })

        settings = SettingsWindowController(
            preferences: preferences, store: store, updater: updater.updater)
        let model = NotchViewModel(preferences: preferences, store: store)
        notch = NotchWindowController(model: model)
        let actions = MenuActions(
            refreshAll: { store.refreshAll() },
            openSettings: { [weak self] in self?.settings.show() },
            checkForUpdates: { [weak self] in self?.updater.checkForUpdates() },
            canCheckForUpdates: { [weak self] in self?.updater.canCheckForUpdates ?? false },
            previewLimit: { kind in model.previewLimitNotification(kind) },
            quit: { NSApp.terminate(nil) }
        )
        model.openSettings = actions.openSettings
        statusItem = StatusItemController(store: store, preferences: preferences, actions: actions)
        installCaptureDemoHook()

        applyPresence()
        observePresence()
        store.start()
        installCheckForUpdatesMenuItem()

        if preferences.isFirstLaunch {
            settings.show()
        }
    }

    /// Reopening from Finder or the Dock brings settings back, which matters when nothing else is on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settings.show()
        return false
    }

    private func observePresence() {
        withObservationTracking {
            _ = preferences.appPresence
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyPresence()
                self?.observePresence()
            }
        }
    }

    private func applyPresence() {
        switch preferences.appPresence {
        case .dock:
            statusItem.hide()
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            statusItem.show()
            NSApp.setActivationPolicy(.accessory)
        case .hidden:
            statusItem.hide()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installCheckForUpdatesMenuItem() {
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let index = min(1, appMenu.numberOfItems)
        appMenu.insertItem(item, at: index)
        if index + 1 <= appMenu.numberOfItems {
            appMenu.insertItem(.separator(), at: index + 1)
        }
    }

    private func installCaptureDemoHook() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("app.lucabecker.AgentNotch.playDemo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notch.model.playCaptureDemo()
        }
        center.addObserver(
            forName: Notification.Name("app.lucabecker.AgentNotch.capturePose"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pose = note.object as? String ?? "arc"
            if pose == "off" {
                self?.notch.model.unfreezeCapture()
            } else {
                self?.notch.model.freezeForCapture(orb: pose == "orb")
            }
        }
        center.addObserver(
            forName: Notification.Name("app.lucabecker.AgentNotch.previewLimit"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let kind: LimitEvent.Kind = (note.object as? String) == "reset" ? .reset : .exhausted
            self?.notch.model.previewLimitNotification(kind)
        }
    }

    @objc private func checkForUpdatesMenu(_ sender: Any?) {
        updater.checkForUpdates()
    }
}
