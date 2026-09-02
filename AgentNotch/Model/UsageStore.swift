import AppKit
import Foundation
import Observation
import os

/// Owns the providers, schedules refreshes and keeps the last good reading per provider.
@Observable
final class UsageStore {
    private static let log = Logger(subsystem: "app.lucabecker.AgentNotch", category: "UsageStore")
    private static let lastGoodKey = "lastGoodReadings"

    /// Regular polling cadence. Providers are cheap local reads plus one small HTTPS call.
    static let refreshInterval: TimeInterval = 60

    private(set) var statuses: [ProviderID: ProviderStatus] = [:]
    private(set) var refreshing: Set<ProviderID> = []
    /// Last non-empty batch of limit transitions. Tests read this; the notch consumes `onLimitEvents`.
    private(set) var latestLimitEvents: [LimitEvent] = []
    /// Increments only when a transition is published, so a silent refresh is observable.
    private(set) var limitEventRevision = 0
    var onLimitEvents: ([LimitEvent]) -> Void = { _ in }

    private let providers: [ProviderID: any UsageProvider]
    private let defaults: UserDefaults
    private var timer: Timer?
    private var inFlight: [ProviderID: Task<Void, Never>] = [:]
    private var wakeObserver: NSObjectProtocol?

    init(providers: [any UsageProvider], defaults: UserDefaults = .standard) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.defaults = defaults
        for id in self.providers.keys {
            statuses[id] = .waiting
        }
        restoreLastGood()
    }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func status(for id: ProviderID) -> ProviderStatus {
        statuses[id] ?? .waiting
    }

    /// Starts periodic polling and refreshes immediately.
    func start() {
        refreshAll()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
    }

    func refreshAll() {
        for id in providers.keys {
            refresh(id)
        }
    }

    func refresh(_ id: ProviderID) {
        guard let provider = providers[id] else { return }
        if inFlight[id] != nil {
            Self.log.debug("refresh skipped: one already in flight for \(id.rawValue)")
            return
        }
        refreshing.insert(id)
        inFlight[id] = Task { [weak self] in
            let outcome: Result<ProviderSnapshot, Error>
            do {
                outcome = .success(try await provider.fetch())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.apply(outcome, for: id)
            self.inFlight[id] = nil
            self.refreshing.remove(id)
        }
    }

    private func apply(_ outcome: Result<ProviderSnapshot, Error>, for id: ProviderID) {
        let previous = statuses[id]?.snapshot
        switch outcome {
        case .success(let snapshot):
            let events = LimitEvent.detect(previous: previous, current: snapshot, now: Date())
            statuses[id] = .ready(snapshot, stale: false)
            persistLastGood()
            if !events.isEmpty {
                latestLimitEvents = events
                limitEventRevision += 1
                onLimitEvents(events)
            }
        case .failure(let error):
            switch error {
            case UsageProviderError.needsAuth(let message):
                statuses[id] = .needsAuth(message)
            case let providerError as UsageProviderError:
                statuses[id] = previous.map { .ready($0, stale: true) } ?? .failed(providerError.message)
            default:
                Self.log.error("\(id.rawValue) refresh failed: \(error.localizedDescription)")
                statuses[id] = previous.map { .ready($0, stale: true) } ?? .failed("Couldn't read usage")
            }
        }
    }

    // MARK: Persistence

    private func persistLastGood() {
        let snapshots = statuses.values.compactMap(\.snapshot)
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: Self.lastGoodKey)
        }
    }

    private func restoreLastGood() {
        guard let data = defaults.data(forKey: Self.lastGoodKey),
            let snapshots = try? JSONDecoder().decode([ProviderSnapshot].self, from: data)
        else { return }
        for snapshot in snapshots where providers[snapshot.id] != nil {
            statuses[snapshot.id] = .ready(snapshot, stale: true)
        }
    }
}
