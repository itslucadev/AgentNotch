import Foundation
import Testing

@testable import AgentNotch

/// Mood changes seen by the view model play their beat on the face, without opening the notch.
@MainActor
struct MoodCueTests {
    private struct ScriptedProvider: UsageProvider {
        let id: ProviderID
        let box: SnapshotBox
        func fetch() async throws -> ProviderSnapshot { box.snapshot }
    }

    private final class SnapshotBox: @unchecked Sendable {
        var snapshot: ProviderSnapshot
        init(_ snapshot: ProviderSnapshot) { self.snapshot = snapshot }
    }

    private func snapshot(fraction: Double, sessions: [AgentSession.Activity] = []) -> ProviderSnapshot {
        let now = Date()
        return ProviderSnapshot(
            id: .claude, account: nil, plan: nil,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: fraction, resetsAt: nil)],
            sessions: sessions.enumerated().map {
                AgentSession(id: "\($0.offset)", name: "s", detail: "", activity: $0.element, startedAt: now)
            },
            fetchedAt: now)
    }

    private func makeModel(visibility: NotchVisibility, box: SnapshotBox) async -> NotchViewModel {
        let defaults = UserDefaults(suiteName: "MoodCueTests.\(UUID().uuidString)")!
        defaults.set(NotchEdge.right.rawValue, forKey: "notchEdge")
        defaults.set(visibility.rawValue, forKey: "notchVisibility")
        defaults.set(
            ProviderID.allCases.filter { $0 != .claude }.map(\.rawValue), forKey: "hiddenProviders")
        let store = UsageStore(providers: [ScriptedProvider(id: .claude, box: box)], defaults: defaults)
        store.refresh(.claude)
        while store.isRefreshing { await Task.yield() }
        return NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
    }

    /// Let the store apply the reading and the observation callback's main-actor turn run.
    private func settle(_ model: NotchViewModel) async {
        while model.store.isRefreshing { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func sessionTurningToTheUserPlaysHey() async {
        let box = SnapshotBox(snapshot(fraction: 0.2, sessions: [.working]))
        let model = await makeModel(visibility: .onHover, box: box)
        #expect(model.mood == .working)
        #expect(model.peekCue == nil)

        box.snapshot = snapshot(fraction: 0.2, sessions: [.waiting])
        model.store.refresh(.claude)
        await settle(model)
        #expect(model.mood == .waiting)
        #expect(model.peekCue == .hey)
        #expect(model.peekCueStart != nil)
        // A mood cue plays where the face is; it never opens the pill.
        #expect(!model.isExpanded)
    }

    @Test func finishedWorkPlaysPhewThenClears() async throws {
        let box = SnapshotBox(snapshot(fraction: 0.2, sessions: [.working]))
        let model = await makeModel(visibility: .alwaysShow, box: box)

        box.snapshot = snapshot(fraction: 0.2, sessions: [.idle])
        model.store.refresh(.claude)
        await settle(model)
        #expect(model.peekCue == .phew)

        try await Task.sleep(for: .seconds(PeekCue.phew.duration + 0.3))
        #expect(model.peekCue == nil)
        #expect(model.peekCueStart == nil)
    }

    @Test func sameMoodAgainIsSilent() async {
        let box = SnapshotBox(snapshot(fraction: 0.2, sessions: [.waiting]))
        let model = await makeModel(visibility: .alwaysShow, box: box)
        #expect(model.peekCue == nil, "opening on an already-waiting session is not a transition")

        box.snapshot = snapshot(fraction: 0.25, sessions: [.waiting])
        model.store.refresh(.claude)
        await settle(model)
        #expect(model.peekCue == nil)
    }

    @Test func headClickPlaysBoop() async {
        let box = SnapshotBox(snapshot(fraction: 0.2))
        let model = await makeModel(visibility: .alwaysShow, box: box)
        model.headClicked()
        #expect(model.peekCue == .boop)
    }

    @Test func enteringCriticalOnAnOpenNotchPlaysTheCreditsLowClip() async {
        let box = SnapshotBox(snapshot(fraction: 0.5, sessions: [.working]))
        let model = await makeModel(visibility: .alwaysShow, box: box)
        #expect(model.peekClip == nil)

        box.snapshot = snapshot(fraction: 0.95, sessions: [.working])
        model.store.refresh(.claude)
        await settle(model)
        #expect(model.mood == .critical)
        #expect(model.peekClip == .creditsLow)
        #expect(model.peekClipStart != nil)
        #expect(model.peekCue == nil, "the authored clip replaces the computed uh-oh")
    }

    @Test func enteringCriticalInThePillKeepsTheUhOhCue() async {
        let box = SnapshotBox(snapshot(fraction: 0.5, sessions: [.working]))
        let model = await makeModel(visibility: .onHover, box: box)

        box.snapshot = snapshot(fraction: 0.95, sessions: [.working])
        model.store.refresh(.claude)
        await settle(model)
        #expect(model.mood == .critical)
        // The clip only draws in the head; folded away, the pill's eyes play the cue instead.
        #expect(model.peekClip == nil)
        #expect(model.peekCue == .uhOh)
        #expect(!model.isExpanded, "a mood beat never opens the notch")
    }

    @Test func aCueAfterAClipStopsTheClip() async {
        let box = SnapshotBox(snapshot(fraction: 0.2))
        let model = await makeModel(visibility: .alwaysShow, box: box)
        model.previewClip(.notification)
        #expect(model.peekClip == .notification)

        model.headClicked()
        #expect(model.peekClip == nil)
        #expect(model.peekClipStart == nil)
        #expect(model.peekCue == .boop)
    }
}
