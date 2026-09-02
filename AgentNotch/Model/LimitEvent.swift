import Foundation

/// A one-shot change in a provider's limit windows: credits ran out, or a window came back.
/// Detected by diffing two snapshots so the same reading never notifies twice.
nonisolated struct LimitEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case exhausted
        case reset
    }

    var provider: ProviderID
    var windowID: String
    var kind: Kind

    /// Diff two readings of the same provider.
    /// No previous reading means no event: opening the app on an already-exhausted window is not a transition.
    static func detect(previous: ProviderSnapshot?, current: ProviderSnapshot, now: Date) -> [LimitEvent] {
        guard let previous else { return [] }
        let oldByID = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0) })
        let currentIDs = Set(current.windows.map(\.id))
        var events: [LimitEvent] = []

        for window in current.windows {
            guard let old = oldByID[window.id] else { continue }
            if window.band == .exhausted, old.band != .exhausted {
                events.append(
                    LimitEvent(provider: current.id, windowID: window.id, kind: .exhausted))
            }
            if didReset(from: old, to: window, now: now) {
                events.append(LimitEvent(provider: current.id, windowID: window.id, kind: .reset))
            }
        }

        for old in previous.windows where !currentIDs.contains(old.id) && old.band == .exhausted {
            events.append(LimitEvent(provider: current.id, windowID: old.id, kind: .reset))
        }
        return events
    }

    /// Credits came back: the window left the exhausted band, usage dropped after the reset time,
    /// or the window was replaced by a later cycle that is no longer exhausted.
    private static func didReset(from old: LimitWindow, to window: LimitWindow, now: Date) -> Bool {
        if old.band == .exhausted, window.band != .exhausted {
            return true
        }
        guard let resetsAt = old.resetsAt, resetsAt <= now else { return false }
        if window.usedFraction < old.usedFraction - 0.02 {
            return true
        }
        if let next = window.resetsAt, next > resetsAt, window.band != .exhausted {
            return true
        }
        return false
    }
}
