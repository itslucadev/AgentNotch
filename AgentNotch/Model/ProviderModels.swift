import Foundation
import SwiftUI

/// Identity of a usage source. Raw values are persisted in preferences.
nonisolated enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case cursor
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    /// Where the account is managed. Cursor and Codex stay in their own apps.
    var manageURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .cursor: URL(string: "https://cursor.com/dashboard")!
        case .codex: URL(string: "https://chatgpt.com/#settings/Account")!
        }
    }

    var manageTitle: String {
        switch self {
        case .claude: "Open Claude"
        case .cursor: "Open Cursor"
        case .codex: "Open Codex"
        }
    }

    /// Name of the tool that owns the credential on this Mac.
    var ownerTool: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    var signInHint: String {
        switch self {
        case .claude: "Sign in with Claude to read your usage"
        case .cursor: "Sign in to Cursor in the editor"
        case .codex: "Sign in to Codex to read your usage"
        }
    }
}

/// One metered limit window, e.g. Claude's five hour session or Cursor's included usage.
nonisolated struct LimitWindow: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var label: String
    /// 0...1, may exceed 1 when a provider reports overage.
    var usedFraction: Double
    var resetsAt: Date?

    var band: UsageBand { UsageBand(fraction: usedFraction) }
}

/// A live agent process owned by the provider's tool, shown under the limits.
nonisolated struct AgentSession: Codable, Sendable, Identifiable, Equatable {
    enum Activity: String, Codable, Sendable {
        case idle
        case working
        case waiting
    }

    var id: String
    var name: String
    var detail: String
    var activity: Activity
    var startedAt: Date
}

/// A complete reading from one provider.
nonisolated struct ProviderSnapshot: Codable, Sendable, Equatable {
    var id: ProviderID
    var account: String?
    var plan: String?
    var windows: [LimitWindow]
    var sessions: [AgentSession] = []
    var fetchedAt: Date

    /// The window that drives the ring: the first one, which every provider orders as its headline.
    var headline: LimitWindow? { windows.first }
}

/// Colour band derived from how much of a window is used.
nonisolated enum UsageBand: Sendable {
    case ample
    case watch
    case critical
    case exhausted

    init(fraction: Double) {
        switch fraction {
        case ..<0.5: self = .ample
        case ..<0.7: self = .watch
        case ..<1.0: self = .critical
        default: self = .exhausted
        }
    }

    var color: Color {
        switch self {
        case .ample: Color(red: 0.13, green: 0.92, blue: 0.53)
        case .watch: Color(red: 0.84, green: 0.89, blue: 0.09)
        case .critical: Color(red: 1.0, green: 0.36, blue: 0.16)
        case .exhausted: Color(red: 1.0, green: 0.23, blue: 0.19)
        }
    }
}

/// What the notch knows about a provider right now.
nonisolated enum ProviderStatus: Sendable, Equatable {
    /// No reading yet and nothing cached.
    case waiting
    /// A reading, possibly stale if `stale` is set because the last refresh failed.
    case ready(ProviderSnapshot, stale: Bool)
    /// The owning tool is signed out or its credential expired.
    case needsAuth(String)
    /// The read failed for another reason.
    case failed(String)

    var snapshot: ProviderSnapshot? {
        if case .ready(let snapshot, _) = self { return snapshot }
        return nil
    }

    var isStale: Bool {
        if case .ready(_, true) = self { return true }
        return false
    }
}

nonisolated enum UsageProviderError: Error, Sendable {
    /// The tool that owns the account is signed out, or the credential is unusable.
    case needsAuth(String)
    /// Nothing to read yet, e.g. Codex has not written a rate limit snapshot.
    case unavailable(String)
    /// The endpoint answered with something unexpected.
    case badResponse(String)

    var message: String {
        switch self {
        case .needsAuth(let message), .unavailable(let message), .badResponse(let message):
            message
        }
    }
}

/// A usage source. Cursor and Codex read credentials already on this Mac. Claude signs in here.
nonisolated protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}
