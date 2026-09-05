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
    /// An authored clip drawn in place of the head. Exclusive with `peekCue`: a beat is one or the other.
    @ObservationIgnored private(set) var peekClip: PeekClip?
    @ObservationIgnored private(set) var peekClipStart: TimeInterval?

    /// True while a limit notification owns expand/hover, so the pointer cannot collapse it.
    private(set) var isNotifying = false
    /// Temporary readings used while a preview or live notification is on screen.
    private var previewStatuses: [ProviderID: ProviderStatus] = [:]

    /// The loudest mood any visible provider justifies. Peek reacts to nothing else.
    var mood: PeekMood {
        providers.map { PeekMood(status: status(for: $0)) }.max() ?? .idle
    }

    func status(for id: ProviderID) -> ProviderStatus {
        previewStatuses[id] ?? store.status(for: id)
    }

    /// Mood at the last change seen, so the next change can pick its cue.
    private var lastMood: PeekMood = .idle
    private var moodCueWork: Task<Void, Never>?

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
        lastMood = mood
        watchMood()
    }

    // MARK: Mood cues

    /// Re-arms after every change: `withObservationTracking` fires once, before the new value lands,
    /// so the check runs on the next main-actor turn.
    private func watchMood() {
        withObservationTracking {
            _ = mood
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.moodDidChange()
                self.watchMood()
            }
        }
    }

    private func moodDidChange() {
        let current = mood
        defer { lastMood = current }
        if let clip = PeekClip.onMoodChange(from: lastMood, to: current), playMoodClip(clip) {
            return
        }
        guard let cue = PeekCue.onMoodChange(from: lastMood, to: current) else { return }
        playMoodCue(cue)
    }

    /// Plays a beat wherever the face is right now; unlike a limit notification it never opens
    /// the notch. A notification in progress owns the cue and wins.
    private func playMoodCue(_ cue: PeekCue) {
        guard !isNotifying, preferences.notchVisibility != .hidden else { return }
        clearBeat()
        peekCue = cue
        peekCueStart = Date().timeIntervalSinceReferenceDate
        scheduleBeatEnd(after: cue.duration)
    }

    /// Same contract as `playMoodCue` for an authored clip. False when the clip cannot be seen,
    /// missing from the bundle or the head folded away in the pill, so the caller falls back to
    /// the computed cue, which the pill's eyes do show.
    @discardableResult
    private func playMoodClip(_ clip: PeekClip) -> Bool {
        guard !isNotifying, preferences.notchVisibility != .hidden else { return true }
        guard isExpanded, let frames = PeekClipLibrary.frames(for: clip) else { return false }
        clearBeat()
        peekClip = clip
        peekClipStart = Date().timeIntervalSinceReferenceDate
        scheduleBeatEnd(after: frames.duration)
        return true
    }

    private func scheduleBeatEnd(after seconds: TimeInterval) {
        moodCueWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.clearBeat()
            self.moodCueWork = nil
        }
    }

    /// Stops whichever beat is playing, cue or clip, and its end timer.
    private func clearBeat() {
        moodCueWork?.cancel()
        peekCue = nil
        peekCueStart = nil
        peekClip = nil
        peekClipStart = nil
    }

    /// The one Easter egg: a click on the head.
    func headClicked() {
        playMoodCue(.boop)
    }

    /// Post `previewClip` with the clip's raw value, or hold Option on the status item menu.
    func previewClip(_ clip: PeekClip) {
        guard preferences.notchVisibility != .hidden else { return }
        cancelNotification(restore: false)
        playMoodClip(clip)
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
        guard preferences.notchVisibility != .hidden, let id = providers.first else { return }
        cancelNotification(restore: false)
        installPreview(kind, for: id)
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
        clearBeat()
        moodCueWork = nil
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
        // A reset plays the authored clip, and the notch stays open until it ends. Exhausted keeps
        // the computed cue; so does a reset if the clip is missing from the bundle.
        let clip: PeekClip? = event.kind == .reset ? .reset : nil
        let frames = clip.flatMap { PeekClipLibrary.frames(for: $0) }
        let hold: Duration = frames.map { .seconds($0.duration + 0.3) } ?? Self.notificationHold
        if frames != nil {
            peekClip = clip
        } else {
            peekCue = event.kind == .exhausted ? .exhausted : .reset
        }
        if !wasCollapsed {
            startBeat(at: Date().timeIntervalSinceReferenceDate)
        }

        notificationWork = Task { @MainActor [weak self] in
            guard let self else { return }
            if wasCollapsed {
                try? await Task.sleep(for: Self.notificationExpandDelay)
                guard !Task.isCancelled else { return }
                self.startBeat(at: Date().timeIntervalSinceReferenceDate)
            }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self.clearBeat()
            self.notificationWork = nil
            if self.notificationQueue.isEmpty {
                self.endNotification()
            } else {
                self.playNextNotification()
            }
        }
    }

    /// Starts whichever beat the notification set, with a blink so the face lands with it.
    private func startBeat(at now: TimeInterval) {
        if peekClip != nil { peekClipStart = now } else { peekCueStart = now }
        peekBlinkAt = now
    }

    private func endNotification() {
        isNotifying = false
        clearBeat()
        previewStatuses.removeAll()
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
        clearBeat()
        moodCueWork = nil
        notificationWork?.cancel()
        notificationWork = nil
        notificationQueue.removeAll()
        previewStatuses.removeAll()
        if restore {
            endNotification()
        } else {
            isNotifying = false
            notificationRestore = nil
        }
    }

    /// Builds a fake reading from the last live snapshot so previews show 100% or a fresh window.
    private func installPreview(_ kind: LimitEvent.Kind, for id: ProviderID) {
        let live = store.status(for: id).snapshot
        let windows: [LimitWindow]
        if let live, !live.windows.isEmpty {
            windows = live.windows.enumerated().map { index, window in
                var window = window
                if kind == .exhausted {
                    window.usedFraction = index == 0 ? 1.0 : min(max(window.usedFraction, 0.74), 0.97)
                } else {
                    window.usedFraction = 0.03 + Double(index) * 0.04
                }
                return window
            }
        } else {
            let resets = Date().addingTimeInterval(kind == .exhausted ? 3_600 : 18_000)
            windows = [
                LimitWindow(
                    id: "session", label: "Current session",
                    usedFraction: kind == .exhausted ? 1.0 : 0.04, resetsAt: resets)
            ]
        }
        let sessions = (live?.sessions ?? []).map { session in
            var session = session
            session.activity = .idle
            return session
        }
        previewStatuses[id] = .ready(
            ProviderSnapshot(
                id: id, account: live?.account, plan: live?.plan, windows: windows, sessions: sessions,
                fetchedAt: Date()),
            stale: false)
    }

}
