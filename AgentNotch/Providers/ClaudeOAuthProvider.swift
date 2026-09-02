import Foundation
import os

nonisolated struct ClaudeOAuthProvider: UsageProvider {
    var id: ProviderID { .claude }

    private static let credentialsService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Keeps the keychain from prompting on every refresh when the user chose Allow instead of Always Allow.
    private static let cache = OSAllocatedUnfairLock<OAuth?>(initialState: nil)

    func fetch() async throws -> ProviderSnapshot {
        var oauth = try currentOAuth()
        var data: Data
        do {
            data = try await usage(with: oauth)
        } catch UsageProviderError.needsAuth {
            // Claude Code may have rotated the token since we cached it; read it once more before giving up.
            Self.cache.withLock { $0 = nil }
            oauth = try currentOAuth()
            data = try await usage(with: oauth)
        }
        let root = try ProviderJSON.object(data)
        return ProviderSnapshot(
            id: .claude,
            account: nil,
            plan: oauth.subscriptionType.map(ProviderJSON.capitalised),
            windows: windows(from: root),
            sessions: ClaudeSessionMonitor.liveSessions(),
            fetchedAt: Date()
        )
    }

    private func currentOAuth() throws -> OAuth {
        if let cached = Self.cache.withLock({ $0 }), cached.expires > Date() {
            return cached
        }
        let oauth = try readOAuth()
        if oauth.expires < Date() {
            throw UsageProviderError.needsAuth("Run Claude Code once to refresh its sign-in")
        }
        Self.cache.withLock { $0 = oauth }
        return oauth
    }

    private func usage(with oauth: OAuth) async throws -> Data {
        try await ProviderHTTP.get(
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(oauth.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
            ],
            authFailed: "Sign in to Claude Code to read your usage"
        )
    }

    private nonisolated struct OAuth: Sendable {
        var accessToken: String
        var expiresAt: Double
        var subscriptionType: String?

        var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
    }

    private func readOAuth() throws -> OAuth {
        guard let data = try Keychain.genericPassword(service: Self.credentialsService) else {
            throw UsageProviderError.needsAuth("Sign in to Claude Code to read your usage")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let expiresAt = ProviderJSON.double(oauth["expiresAt"])
        else {
            throw UsageProviderError.needsAuth("Sign in to Claude Code to read your usage")
        }
        let subscription = oauth["subscriptionType"] as? String
        return OAuth(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: subscription.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func windows(from root: [String: Any]) -> [LimitWindow] {
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

    private func bucketWindow(_ raw: Any?, id: String, label: String) -> LimitWindow? {
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
