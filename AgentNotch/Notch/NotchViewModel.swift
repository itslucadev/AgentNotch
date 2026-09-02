import CoreGraphics
import Foundation
import Observation
import os

/// Interaction state for the notch. Geometry comes from `NotchLayout`.
@Observable
final class NotchViewModel {
    let preferences: Preferences
    let store: UsageStore
    var openSettings: () -> Void = {}

    private static let log = Logger(subsystem: "app.lucabecker.AgentNotch", category: "Notch")

    private(set) var isExpanded: Bool {
        didSet {
            Self.log.debug("expanded=\(self.isExpanded)")
            // Peek blinks mid-spring so the head's size change hides behind a closed lid.
            peekBlinkAt = Date().timeIntervalSinceReferenceDate + 0.21
        }
    }
    private(set) var hoveredProvider: ProviderID? {
        didSet { Self.log.debug("hovered=\(self.hoveredProvider?.rawValue ?? "none")") }
    }
    private(set) var isOrbHovered = false {
        didSet { Self.log.debug("orbHovered=\(self.isOrbHovered)") }
    }
    /// Cumulative spin turns per provider; each click adds a full turn.
    private(set) var spinTurns: [ProviderID: Int] = [:]
    /// Reported by the tooltip view once laid out, so hit testing knows its real height.
    var tooltipHeight: CGFloat = 0

    // MARK: Peek
    // Read inside the face's timeline on every tick, so none of it needs to invalidate the view tree.

    /// Last pointer position in panel coordinates, nil when outside the panel.
    @ObservationIgnored private(set) var pointer: CGPoint?
    /// When the last refresh click happened, so the eyes can roll along with the ring.
    @ObservationIgnored private(set) var refreshRollStart: TimeInterval?
    @ObservationIgnored private(set) var peekBlinkAt: TimeInterval?
    @ObservationIgnored private(set) var peekCue: PeekCue?
    @ObservationIgnored private(set) var peekCueStart: TimeInterval?

    /// True while a limit notification owns expand/hover, so the pointer cannot collapse it.
    private(set) var isNotifying = false

    /// The loudest mood any visible provider justifies. Peek reacts to nothing else.
    var mood: PeekMood {
        providers.map { PeekMood(status: store.status(for: $0)) }.max() ?? .idle
    }

    private var foldWork: Task<Void, Never>?
    private var unhoverWork: Task<Void, Never>?

    private var demoWork: Task<Void, Never>?
    private var notificationWork: Task<Void, Never>?
    private var notificationQueue: [LimitEvent] = []
    private var notificationRestore: (expanded: Bool, hover: ProviderID?, orb: Bool)?

    private static let notificationHold: Duration = .milliseconds(3400)
    private static let notificationExpandDelay: Duration = .milliseconds(300)
    /// While a capture demo is playing, ignore the real pointer so it cannot collapse the notch.
    private var isDemoPlaying = false

    /// How long the notch stays open after the pointer leaves it.
    private static let foldGrace: Duration = .milliseconds(450)
    /// How long a tooltip lingers while the pointer travels between cells or into the card.
    private static let hoverGrace: Duration = .milliseconds(120)

    init(preferences: Preferences, store: UsageStore) {
        self.preferences = preferences
        self.store = store
        isExpanded = preferences.notchVisibility == .alwaysShow
        store.onLimitEvents = { [weak self] events in
            self?.handleLimitEvents(events)
        }
    }

    var providers: [ProviderID] { preferences.visibleProviders }
    var edge: NotchEdge { preferences.notchEdge }

    var layout: NotchLayout {
        NotchLayout(edge: edge, cells: providers.count, isExpanded: isExpanded, tooltipHeight: tooltipHeight)
    }

    /// Size depends only on edge and cell count, so the panel is not resized while expanding.
    var panelSize: CGSize {
        NotchLayout(edge: edge, cells: providers.count, isExpanded: true, tooltipHeight: 0).panelSize
    }

    var hoveredIndex: Int? {
        hoveredProvider.flatMap { providers.firstIndex(of: $0) }
    }

    // MARK: Interaction

    /// Called for every pointer move. `point` is nil when the pointer is outside the panel.
    func pointerMoved(to point: CGPoint?) {
        pointer = point
        let visibility = preferences.notchVisibility
        guard !isDemoPlaying, !isNotifying else { return }

        guard visibility != .hidden else { return }
        let layout = layout

        let inShape = point.map { layout.shapeRect.insetBy(dx: -4, dy: -4).contains($0) } ?? false
        let inTooltip = point.flatMap { p in hoveredIndex.map { layout.tooltipHotRect(for: $0).contains(p) } } ?? false
        let inOrb = point.map { isExpanded && layout.orbHotRect(orbShown: isOrbHovered).contains($0) } ?? false
        let inHead = point.map { isExpanded && layout.headRect.contains($0) } ?? false

        if visibility == .onHover {
            if inShape || inTooltip || inOrb || inHead {
                foldWork?.cancel()
                foldWork = nil
                if !isExpanded { isExpanded = true }
            } else if isExpanded, foldWork == nil {
                foldWork = Task { [weak self] in
                    try? await Task.sleep(for: Self.foldGrace)
                    guard !Task.isCancelled, let self else { return }
                    self.isExpanded = false
                    self.hoveredProvider = nil
                    self.isOrbHovered = false
                    self.foldWork = nil
                }
            }
        }

        guard isExpanded else { return }

        if inOrb != isOrbHovered { isOrbHovered = inOrb }

        let cellHit = point.flatMap { p in
            providers.indices.first { layout.cellRect($0).contains(p) }.map { providers[$0] }
        }
        if let cellHit {
            unhoverWork?.cancel()
            unhoverWork = nil
            if hoveredProvider != cellHit { hoveredProvider = cellHit }
        } else if inTooltip {
            unhoverWork?.cancel()
            unhoverWork = nil
        } else if hoveredProvider != nil, unhoverWork == nil {
            unhoverWork = Task { [weak self] in
                try? await Task.sleep(for: Self.hoverGrace)
                guard !Task.isCancelled, let self else { return }
                self.hoveredProvider = nil
                self.unhoverWork = nil
            }
        }
    }

    func visibilityChanged() {
        cancelNotification(restore: false)
        foldWork?.cancel()
        foldWork = nil
        switch preferences.notchVisibility {
        case .alwaysShow: isExpanded = true
        case .onHover, .hidden:
            isExpanded = false
            hoveredProvider = nil
            isOrbHovered = false
        }
    }

    func cellClicked(_ id: ProviderID) {
        spinTurns[id, default: 0] += 1
        refreshRollStart = Date().timeIntervalSinceReferenceDate
        store.refresh(id)
    }

    func orbClicked() {
        openSettings()
    }

    /// Walks the notch through collapsed → expanded → tooltips → settings orb → collapsed.
    /// Posted from outside via `app.lucabecker.AgentNotch.playDemo` for marketing captures.
    func playCaptureDemo() {
        cancelNotification(restore: false)
        demoWork?.cancel()
        foldWork?.cancel()
        unhoverWork?.cancel()
        foldWork = nil
        unhoverWork = nil
        demoWork = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isDemoPlaying = true
            defer {
                self.isDemoPlaying = false
                self.demoWork = nil
            }
            self.isExpanded = false
            self.hoveredProvider = nil
            self.isOrbHovered = false
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self.isExpanded = true
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            if let first = self.providers.first {
                self.hoveredProvider = first
            }
            try? await Task.sleep(for: .milliseconds(1700))
            guard !Task.isCancelled else { return }
            if self.providers.count > 1 {
                self.hoveredProvider = self.providers[1]
            }
            try? await Task.sleep(for: .milliseconds(1700))
            guard !Task.isCancelled else { return }
            self.hoveredProvider = nil
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self.isOrbHovered = true
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self.isOrbHovered = false
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            self.isExpanded = false
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    /// Holds an expanded still for screenshots. `orb` shows the gear instead of the settings arc.
    func freezeForCapture(orb: Bool) {
        cancelNotification(restore: false)
        demoWork?.cancel()
        foldWork?.cancel()
        unhoverWork?.cancel()
        demoWork = nil
        foldWork = nil
        unhoverWork = nil
        isDemoPlaying = true
        isExpanded = true
        hoveredProvider = nil
        isOrbHovered = orb
    }

    func unfreezeCapture() {
        isDemoPlaying = false
        isOrbHovered = false
        hoveredProvider = nil
        visibilityChanged()
    }

    // MARK: Limit notifications

    /// Hold Option on the status item menu to fire these, or post `previewLimit`.
    func previewLimitNotification(_ kind: LimitEvent.Kind) {
        guard let id = providers.first else { return }
        cancelNotification(restore: false)
        handleLimitEvents(
            [LimitEvent(provider: id, windowID: "debug", kind: kind)], replaceQueue: true)
    }

    func handleLimitEvents(_ events: [LimitEvent]) {
        handleLimitEvents(events, replaceQueue: false)
    }

    private func handleLimitEvents(_ events: [LimitEvent], replaceQueue: Bool) {
        guard preferences.notchVisibility != .hidden else { return }
        let incoming = events.filter { providers.contains($0.provider) }
        guard !incoming.isEmpty else { return }
        if replaceQueue {
            notificationQueue = incoming
        } else {
            for event in incoming
            where !notificationQueue.contains(where: {
                $0.provider == event.provider && $0.kind == event.kind
            }) {
                notificationQueue.append(event)
            }
        }
        if notificationWork == nil {
            playNextNotification()
        }
    }

    private func playNextNotification() {
        guard let event = notificationQueue.first else {
            endNotification()
            return
        }
        notificationQueue.removeFirst()
        if !isNotifying {
            notificationRestore = (isExpanded, hoveredProvider, isOrbHovered)
        }
        isNotifying = true
        foldWork?.cancel()
        unhoverWork?.cancel()
        foldWork = nil
        unhoverWork = nil
        demoWork?.cancel()
        demoWork = nil
        isDemoPlaying = false

        let wasCollapsed = !isExpanded
        isExpanded = true
        hoveredProvider = event.provider
        isOrbHovered = false
        peekCue = event.kind == .exhausted ? .exhausted : .reset
        if wasCollapsed {
            peekCueStart = nil
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            peekCueStart = now
            peekBlinkAt = now
        }

        notificationWork = Task { @MainActor [weak self] in
            guard let self else { return }
            if wasCollapsed {
                try? await Task.sleep(for: Self.notificationExpandDelay)
                guard !Task.isCancelled else { return }
                let now = Date().timeIntervalSinceReferenceDate
                self.peekCueStart = now
                self.peekBlinkAt = now
            }
            try? await Task.sleep(for: Self.notificationHold)
            guard !Task.isCancelled else { return }
            self.peekCue = nil
            self.peekCueStart = nil
            self.notificationWork = nil
            if self.notificationQueue.isEmpty {
                self.endNotification()
            } else {
                self.playNextNotification()
            }
        }
    }

    private func endNotification() {
        isNotifying = false
        peekCue = nil
        peekCueStart = nil
        if let restore = notificationRestore {
            isExpanded = restore.expanded
            hoveredProvider = restore.hover
            isOrbHovered = restore.orb
        }
        notificationRestore = nil
        if preferences.notchVisibility == .alwaysShow {
            isExpanded = true
        }
        pointerMoved(to: pointer)
    }

    private func cancelNotification(restore: Bool) {
        notificationWork?.cancel()
        notificationWork = nil
        notificationQueue.removeAll()
        peekCue = nil
        peekCueStart = nil
        if restore {
            endNotification()
        } else {
            isNotifying = false
            notificationRestore = nil
        }
    }
}
