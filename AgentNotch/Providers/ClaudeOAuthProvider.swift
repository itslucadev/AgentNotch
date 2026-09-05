import Foundation
import os

nonisolated struct ClaudeOAuthProvider: UsageProvider {
    var id: ProviderID { .claude }

    private static let cache = OSAllocatedUnfairLock<ClaudeOAuthSession?>(initialState: nil)

    func fetch() async throws -> ProviderSnapshot {
        var session = try await currentSession()
        var data: Data
        do {
            data = try await usage(with: session)
        } catch UsageProviderError.needsAuth {
            Self.cache.withLock { $0 = nil }
            session = try await ClaudeOAuthLogin.refresh(session)
            data = try await usage(with: session)
        }
        let root = try ProviderJSON.object(data)
        return ProviderSnapshot(
            id: .claude,
            account: session.email,
            plan: nil,
            windows: windows(from: root),
            sessions: ClaudeSessionMonitor.liveSessions(),
            fetchedAt: Date()
        )
    }

    static func forgetSession() {
        cache.withLock { $0 = nil }
    }

    private func currentSession() async throws -> ClaudeOAuthSession {
        if let cached = Self.cache.withLock({ $0 }), !cached.needsRefresh {
            return cached
        }
        guard var session = try ClaudeOAuthStore.load() else {
            throw UsageProviderError.needsAuth(ProviderID.claude.signInHint)
        }
        if session.needsRefresh {
            session = try await ClaudeOAuthLogin.refresh(session)
        }
        let ready = session
        Self.cache.withLock { $0 = ready }
        return ready
    }

    private func usage(with session: ClaudeOAuthSession) async throws -> Data {
        try await ProviderHTTP.get(
            url: ClaudeOAuth.usageEndpoint,
            headers: [
                "Authorization": "Bearer \(session.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
            ],
            authFailed: ProviderID.claude.signInHint
        )
    }

    func windows(from root: [String: Any]) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let window = bucketWindow(
            root["five_hour"],
            id: "session",
            label: "Current session"
        ) {
            windows.append(window)
        }
        if let window = bucketWindow(
            root["seven_day"],
            id: "weekly",
            label: "All models"
        ) {
            windows.append(window)
        }
        let limits = root["limits"] as? [Any] ?? []
        for entry in limits {
            guard let object = entry as? [String: Any],
                object["kind"] as? String == "weekly_scoped",
                let scope = object["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let displayName = model["display_name"] as? String, !displayName.isEmpty,
                let percent = ProviderJSON.double(object["percent"])
            else { continue }
            windows.append(
                LimitWindow(
                    id: "weekly_\(displayName.lowercased())",
                    label: displayName,
                    usedFraction: percent / 100,
                    resetsAt: (object["resets_at"] as? String).flatMap(JSONDate.parse)
                )
            )
        }
        return windows
    }

    func bucketWindow(_ raw: Any?, id: String, label: String) -> LimitWindow? {
        guard let object = raw as? [String: Any],
            let utilization = ProviderJSON.double(object["utilization"])
        else { return nil }
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: utilization / 100,
            resetsAt: (object["resets_at"] as? String).flatMap(JSONDate.parse)
        )
    }
}
