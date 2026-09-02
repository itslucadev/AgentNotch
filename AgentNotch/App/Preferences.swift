import Foundation
import Observation
import ServiceManagement

nonisolated enum NotchEdge: String, CaseIterable, Identifiable {
    case right
    case left
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    var detail: String {
        switch self {
        case .right: "Down the right-hand edge, clear of a Dock on that side."
        case .left: "Down the left-hand edge, clear of a Dock on that side."
        case .top: "Hanging from the menu bar, readings side by side."
        case .bottom: "A wide bar resting on top of the Dock, readings side by side."
        }
    }
}

nonisolated enum NotchVisibility: String, CaseIterable, Identifiable {
    case alwaysShow
    case onHover
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysShow: "Always show"
        case .onHover: "Show on hover"
        case .hidden: "Hide"
        }
    }

    var detail: String {
        switch self {
        case .alwaysShow: "The notch stays open with every reading visible."
        case .onHover: "A small pill at the screen edge that opens when you reach it."
        case .hidden:
            "Nothing on screen. Open Agent Notch again from Applications to bring these settings back."
        }
    }
}

nonisolated enum AppPresence: String, CaseIterable, Identifiable {
    case dock
    case menuBar
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .menuBar: "Menu bar"
        case .hidden: "Hidden"
        }
    }

    var detail: String {
        switch self {
        case .dock: "A normal app icon in the Dock while Agent Notch is running."
        case .menuBar: "A small icon in the menu bar instead, and nothing in the Dock."
        case .hidden:
            "No icon anywhere. Open Agent Notch again from Applications to bring these settings back."
        }
    }
}

/// User preferences, backed by UserDefaults and observable by the UI.
@Observable
final class Preferences {
    private enum Key {
        static let notchEdge = "notchEdge"
        static let notchVisibility = "notchVisibility"
        static let appPresence = "appPresence"
        static let hiddenProviders = "hiddenProviders"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    private let defaults: UserDefaults

    var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Key.notchEdge) }
    }

    var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Key.notchVisibility) }
    }

    var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Key.appPresence) }
    }

    var hiddenProviders: Set<ProviderID> {
        didSet {
            defaults.set(hiddenProviders.map(\.rawValue).sorted(), forKey: Key.hiddenProviders)
        }
    }

    /// Mirrors `SMAppService.mainApp`; writes register or unregister the login item.
    var opensAtLogin: Bool {
        didSet {
            guard opensAtLogin != oldValue else { return }
            do {
                if opensAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                loginItemError = error.localizedDescription
                opensAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private(set) var loginItemError: String?

    let isFirstLaunch: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchEdge = defaults.string(forKey: Key.notchEdge).flatMap(NotchEdge.init) ?? .right
        notchVisibility =
            defaults.string(forKey: Key.notchVisibility).flatMap(NotchVisibility.init)
            ?? .alwaysShow
        appPresence = defaults.string(forKey: Key.appPresence).flatMap(AppPresence.init) ?? .menuBar
        let hidden = defaults.stringArray(forKey: Key.hiddenProviders) ?? []
        hiddenProviders = Set(hidden.compactMap(ProviderID.init))
        opensAtLogin = SMAppService.mainApp.status == .enabled
        isFirstLaunch = !defaults.bool(forKey: Key.hasLaunchedBefore)
        defaults.set(true, forKey: Key.hasLaunchedBefore)
    }

    var visibleProviders: [ProviderID] {
        ProviderID.allCases.filter { !hiddenProviders.contains($0) }
    }

    func setProvider(_ id: ProviderID, enabled: Bool) {
        if enabled {
            hiddenProviders.remove(id)
        } else {
            hiddenProviders.insert(id)
        }
    }
}
