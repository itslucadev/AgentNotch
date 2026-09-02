import Foundation
import Testing

@testable import AgentNotch

struct LimitEventTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ id: ProviderID = .claude,
        windows: [LimitWindow],
        fetchedAt: Date? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, account: nil, plan: nil, windows: windows, sessions: [],
            fetchedAt: fetchedAt ?? now)
    }

    private func window(
        _ id: String, fraction: Double, resetsAt: Date? = nil
    ) -> LimitWindow {
        LimitWindow(id: id, label: id, usedFraction: fraction, resetsAt: resetsAt)
    }

    @Test func noPreviousReadingProducesNoEvent() {
        let current = snapshot(windows: [window("session", fraction: 1.0)])
        #expect(LimitEvent.detect(previous: nil, current: current, now: now).isEmpty)
    }

    @Test func enteringExhaustedFiresOnce() {
        let previous = snapshot(windows: [window("session", fraction: 0.91)])
        let current = snapshot(windows: [window("session", fraction: 1.0)])
        let events = LimitEvent.detect(previous: previous, current: current, now: now)
        #expect(events == [LimitEvent(provider: .claude, windowID: "session", kind: .exhausted)])
        #expect(LimitEvent.detect(previous: current, current: current, now: now).isEmpty)
    }

    @Test func overageWhileAlreadyExhaustedIsNotANewEvent() {
        let previous = snapshot(windows: [window("session", fraction: 1.0)])
        let current = snapshot(windows: [window("session", fraction: 1.14)])
        #expect(LimitEvent.detect(previous: previous, current: current, now: now).isEmpty)
    }

    @Test func leavingExhaustedFiresReset() {
        let previous = snapshot(windows: [window("session", fraction: 1.0)])
        let current = snapshot(windows: [window("session", fraction: 0.04)])
        let events = LimitEvent.detect(previous: previous, current: current, now: now)
        #expect(events == [LimitEvent(provider: .claude, windowID: "session", kind: .reset)])
    }

    @Test func dropWithoutHavingBeenExhaustedIsSilent() {
        let previous = snapshot(windows: [window("session", fraction: 0.7)])
        let current = snapshot(windows: [window("session", fraction: 0.0)])
        #expect(LimitEvent.detect(previous: previous, current: current, now: now).isEmpty)
    }

    @Test func resetsAtPassingWithADropFiresReset() {
        let due = now.addingTimeInterval(-60)
        let previous = snapshot(windows: [window("week", fraction: 0.88, resetsAt: due)])
        let current = snapshot(
            windows: [window("week", fraction: 0.12, resetsAt: now.addingTimeInterval(86_400))])
        let events = LimitEvent.detect(previous: previous, current: current, now: now)
        #expect(events == [LimitEvent(provider: .claude, windowID: "week", kind: .reset)])
    }

    @Test func resetsAtStillInTheFutureDoesNotFire() {
        let due = now.addingTimeInterval(600)
        let previous = snapshot(windows: [window("week", fraction: 0.5, resetsAt: due)])
        let current = snapshot(windows: [window("week", fraction: 0.1, resetsAt: due)])
        #expect(LimitEvent.detect(previous: previous, current: current, now: now).isEmpty)
    }

    @Test func disappearedExhaustedWindowCountsAsReset() {
        let previous = snapshot(windows: [
            window("session", fraction: 1.0),
            window("week", fraction: 0.2),
        ])
        let current = snapshot(windows: [window("week", fraction: 0.2)])
        let events = LimitEvent.detect(previous: previous, current: current, now: now)
        #expect(events == [LimitEvent(provider: .claude, windowID: "session", kind: .reset)])
    }

    @Test func onlyTheWindowThatChangedFires() {
        let previous = snapshot(windows: [
            window("session", fraction: 0.4),
            window("week", fraction: 0.95),
        ])
        let current = snapshot(windows: [
            window("session", fraction: 0.4),
            window("week", fraction: 1.0),
        ])
        let events = LimitEvent.detect(previous: previous, current: current, now: now)
        #expect(events == [LimitEvent(provider: .claude, windowID: "week", kind: .exhausted)])
    }

    @Test func criticalToExhaustedIsTheBoundary() {
        let previous = snapshot(windows: [window("session", fraction: 0.99)])
        let current = snapshot(windows: [window("session", fraction: 1.0)])
        #expect(
            LimitEvent.detect(previous: previous, current: current, now: now).map(\.kind) == [
                .exhausted
            ])
    }

    @Test func eventsCarryTheProvider() {
        let previous = snapshot(.cursor, windows: [window("included", fraction: 0.8)])
        let current = snapshot(.cursor, windows: [window("included", fraction: 1.0)])
        #expect(
            LimitEvent.detect(previous: previous, current: current, now: now)
                == [LimitEvent(provider: .cursor, windowID: "included", kind: .exhausted)])
    }
}
