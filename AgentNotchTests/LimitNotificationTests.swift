import Foundation
import Testing

@testable import AgentNotch

@MainActor
struct LimitNotificationTests {
    private struct ScriptedProvider: UsageProvider {
        let id: ProviderID
        let box: SnapshotBox
        func fetch() async throws -> ProviderSnapshot { box.snapshot }
    }

    private final class SnapshotBox: @unchecked Sendable {
        var snapshot: ProviderSnapshot
        init(_ snapshot: ProviderSnapshot) { self.snapshot = snapshot }
    }

    private func window(_ fraction: Double) -> LimitWindow {
        LimitWindow(id: "session", label: "Session", usedFraction: fraction, resetsAt: nil)
    }

    private func snapshot(_ fraction: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .claude, account: nil, plan: nil,
            windows: [window(fraction)], sessions: [], fetchedAt: Date())
    }

    private func makeDefaults(visibility: NotchVisibility) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "LimitNotificationTests.\(UUID().uuidString)")!
        defaults.set(NotchEdge.right.rawValue, forKey: "notchEdge")
        defaults.set(visibility.rawValue, forKey: "notchVisibility")
        defaults.set(
            ProviderID.allCases.filter { $0 != .claude }.map(\.rawValue), forKey: "hiddenProviders")
        return defaults
    }

    private func waitUntilIdle(_ store: UsageStore) async {
        while store.isRefreshing { await Task.yield() }
    }

    @Test func storeDiffFiresExhaustedThenResetOnceEach() async {
        let defaults = makeDefaults(visibility: .alwaysShow)
        let box = SnapshotBox(snapshot(0.4))
        let store = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: box)], defaults: defaults)
        store.refresh(.claude)
        await waitUntilIdle(store)
        #expect(store.latestLimitEvents.isEmpty)

        box.snapshot = snapshot(1.0)
        store.refresh(.claude)
        await waitUntilIdle(store)
        #expect(store.latestLimitEvents.map(\.kind) == [.exhausted])
        let revision = store.limitEventRevision

        box.snapshot = snapshot(1.0)
        store.refresh(.claude)
        await waitUntilIdle(store)
        #expect(store.limitEventRevision == revision)

        box.snapshot = snapshot(0.0)
        store.refresh(.claude)
        await waitUntilIdle(store)
        #expect(store.latestLimitEvents.map(\.kind) == [.reset])
    }

    @Test func previewOpensTooltipAndStartsExhaustedCue() {
        let defaults = makeDefaults(visibility: .alwaysShow)
        let store = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: SnapshotBox(snapshot(0.2)))],
            defaults: defaults)
        let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
        #expect(model.isExpanded)
        #expect(model.hoveredProvider == nil)

        model.previewLimitNotification(.exhausted)
        #expect(model.isNotifying)
        #expect(model.isExpanded)
        #expect(model.hoveredProvider == .claude)
        #expect(model.peekCue == .exhausted)
        #expect(model.status(for: .claude).snapshot?.headline?.band == .exhausted)
    }

    @Test func previewOnHoverExpandsThePill() {
        let defaults = makeDefaults(visibility: .onHover)
        let store = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: SnapshotBox(snapshot(0.2)))],
            defaults: defaults)
        let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
        #expect(!model.isExpanded)

        model.previewLimitNotification(.reset)
        #expect(model.isNotifying)
        #expect(model.isExpanded)
        #expect(model.hoveredProvider == .claude)
        // A reset plays the authored clip; the pill was collapsed, so it starts once the head is out.
        #expect(model.peekCue == nil)
        #expect(model.peekClip == .reset)
        #expect(model.peekClipStart == nil)
        #expect((model.status(for: .claude).snapshot?.headline?.usedFraction ?? 1) < 0.1)
    }

    @Test func hiddenVisibilityDoesNotNotify() {
        let defaults = makeDefaults(visibility: .hidden)
        let store = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: SnapshotBox(snapshot(0.2)))],
            defaults: defaults)
        let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)

        model.previewLimitNotification(.exhausted)
        #expect(!model.isNotifying)
        #expect(!model.isExpanded)
        #expect(model.peekCue == nil)
        #expect(model.hoveredProvider == nil)
    }

    @Test func storeTransitionPlaysThroughTheViewModel() async {
        let defaults = makeDefaults(visibility: .alwaysShow)
        let box = SnapshotBox(snapshot(0.3))
        let store = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: box)], defaults: defaults)
        let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
        store.refresh(.claude)
        await waitUntilIdle(store)
        #expect(!model.isNotifying)

        box.snapshot = snapshot(1.0)
        store.refresh(.claude)
        await waitUntilIdle(store)
        #expect(model.isNotifying)
        #expect(model.hoveredProvider == .claude)
        #expect(model.peekCue == .exhausted)
    }

    @Test func resetOnAnOpenNotchStartsTheClipAtOnce() {
        let defaults = makeDefaults(visibility: .alwaysShow)
        let store = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: SnapshotBox(snapshot(0.2)))],
            defaults: defaults)
        let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
        #expect(model.isExpanded)

        model.previewLimitNotification(.reset)
        #expect(model.isNotifying)
        #expect(model.peekClip == .reset)
        #expect(model.peekClipStart != nil)
        #expect(model.peekCue == nil)

        // Exhausted right after: the clip yields to the computed cue, never both at once.
        model.previewLimitNotification(.exhausted)
        #expect(model.peekClip == nil)
        #expect(model.peekCue == .exhausted)
    }
}
