import AppKit
import Sparkle
import SwiftUI

/// Single settings window, created on first use and reused afterwards.
final class SettingsWindowController {
    private let preferences: Preferences
    private let updater: SPUUpdater
    private let store: UsageStore
    private let onClaudeSignIn: () async throws -> Void
    private let onClaudeSignOut: () -> Void
    private var window: NSWindow?

    init(
        preferences: Preferences,
        store: UsageStore,
        updater: SPUUpdater,
        onClaudeSignIn: @escaping () async throws -> Void,
        onClaudeSignOut: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.store = store
        self.updater = updater
        self.onClaudeSignIn = onClaudeSignIn
        self.onClaudeSignOut = onClaudeSignOut
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                store: store,
                updater: updater,
                onClaudeSignIn: onClaudeSignIn,
                onClaudeSignOut: onClaudeSignOut
            ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Agent Notch Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setContentSize(hosting.view.fittingSize)
        return window
    }
}
