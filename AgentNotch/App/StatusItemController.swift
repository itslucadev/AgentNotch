import AppKit

/// Menu bar item with a compact usage readout and the app's actions.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let preferences: Preferences
    private let actions: MenuActions
    private var item: NSStatusItem?

    init(store: UsageStore, preferences: Preferences, actions: MenuActions) {
        self.store = store
        self.preferences = preferences
        self.actions = actions
    }

    var isShown: Bool { item != nil }

    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon
        item.button?.toolTip = "Agent Notch"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    func hide() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for id in preferences.visibleProviders {
            let entry = NSMenuItem(title: readout(for: id), action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        if !preferences.visibleProviders.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: store.isRefreshing ? "Refreshing…" : "Refresh Now",
            action: #selector(refresh), keyEquivalent: "r"
        ).target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        let updates = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        updates.isEnabled = actions.canCheckForUpdates()
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "Preview Credits Exhausted",
                action: #selector(previewExhausted), keyEquivalent: ""
            ).target = self
            menu.addItem(
                withTitle: "Preview Limit Reset",
                action: #selector(previewReset), keyEquivalent: ""
            ).target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent Notch", action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    private func readout(for id: ProviderID) -> String {
        switch store.status(for: id) {
        case .ready(let snapshot, let stale):
            let percent =
                snapshot.headline.map { "\(Int(($0.usedFraction * 100).rounded()))%" } ?? "--"
            return "\(id.displayName)  \(percent)\(stale ? " (stale)" : "")"
        case .waiting: return "\(id.displayName)  waiting"
        case .needsAuth: return "\(id.displayName)  signed out"
        case .failed: return "\(id.displayName)  unavailable"
        }
    }

    @objc private func refresh() { actions.refreshAll() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func quit() { actions.quit() }
    @objc private func previewExhausted() { actions.previewLimit(.exhausted) }
    @objc private func previewReset() { actions.previewLimit(.reset) }

    /// Template image: a small side notch hugging the right edge of the icon.
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 3.5, width: 11, height: 11))
            ring.lineWidth = 1.8
            NSColor.black.setStroke()
            ring.stroke()
            let notch = NSBezierPath(
                roundedRect: NSRect(x: 14, y: 2, width: 4, height: 14),
                byRoundingCorners: [.topLeft, .bottomLeft],
                cornerRadius: 2
            )
            NSColor.black.setFill()
            notch.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

extension NSBezierPath {
    fileprivate struct Corners: OptionSet {
        let rawValue: Int
        static let topLeft = Corners(rawValue: 1)
        static let bottomLeft = Corners(rawValue: 2)
    }

    fileprivate convenience init(
        roundedRect rect: NSRect, byRoundingCorners corners: Corners, cornerRadius radius: CGFloat
    ) {
        self.init()
        let topLeft = corners.contains(.topLeft) ? radius : 0
        let bottomLeft = corners.contains(.bottomLeft) ? radius : 0
        move(to: NSPoint(x: rect.maxX, y: rect.minY))
        line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        line(to: NSPoint(x: rect.minX + topLeft, y: rect.maxY))
        appendArc(
            withCenter: NSPoint(x: rect.minX + topLeft, y: rect.maxY - topLeft), radius: topLeft,
            startAngle: 90, endAngle: 180)
        line(to: NSPoint(x: rect.minX, y: rect.minY + bottomLeft))
        appendArc(
            withCenter: NSPoint(x: rect.minX + bottomLeft, y: rect.minY + bottomLeft),
            radius: bottomLeft, startAngle: 180, endAngle: 270)
        close()
    }
}
